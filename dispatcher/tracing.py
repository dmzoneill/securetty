"""OpenTelemetry span instrumentation for the securetty dispatcher.

Provides lightweight tracing wrappers around the dispatcher's job lifecycle.
Uses ``opentelemetry-api`` only (no SDK bundled) so the module adds zero
overhead when no OTEL collector is configured.

Spans mirror the dispatch pipeline documented in docs/observability.md::

    dispatch  -->  route  -->  execute  -->  complete

Enable tracing by setting ``OTEL_EXPORTER_OTLP_ENDPOINT`` in the environment
(e.g. ``http://tempo:4317``).  When the variable is absent or empty every
function in this module is a silent no-op -- no traces are created and no
network calls are made.
"""

from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Any, Generator

# ---------------------------------------------------------------------------
# Detect whether tracing should be active.  We key off the standard OTEL
# environment variable -- if it is set we attempt to import the trace API;
# if the package is missing we fall back to no-op mode gracefully.
# ---------------------------------------------------------------------------

_OTEL_ENDPOINT: str = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "")

_tracer: Any = None  # opentelemetry.trace.Tracer | None
_trace_mod: Any = None  # opentelemetry.trace module reference
_status_mod: Any = None  # opentelemetry.trace.StatusCode enum

if _OTEL_ENDPOINT:
    try:
        from opentelemetry import (
            trace as _trace_mod_import,  # type: ignore[import-untyped]
        )
        from opentelemetry.trace import (
            StatusCode as _StatusCode,  # type: ignore[import-untyped]
        )

        _trace_mod = _trace_mod_import
        _status_mod = _StatusCode
        _tracer = _trace_mod.get_tracer("securetty.dispatcher")
    except ImportError:
        # opentelemetry-api is not installed -- stay in no-op mode.
        _tracer = None


# ---------------------------------------------------------------------------
# Canonical span names used throughout the dispatcher.
# ---------------------------------------------------------------------------

SPAN_DISPATCH = "dispatch"
SPAN_ROUTE = "route"
SPAN_EXECUTE = "execute"
SPAN_COMPLETE = "complete"


# ---------------------------------------------------------------------------
# Public helpers
# ---------------------------------------------------------------------------


def start_span(
    name: str,
    attributes: dict[str, str | int | float | bool] | None = None,
) -> Any:
    """Begin a new OTEL span and return it.

    If tracing is not configured (no endpoint or missing library) this
    returns ``None`` and performs no work.

    Args:
        name: Span name -- should be one of the ``SPAN_*`` constants.
        attributes: Optional key/value attributes to attach to the span.

    Returns:
        An ``opentelemetry.trace.Span`` instance, or ``None`` when tracing
        is disabled.
    """
    if _tracer is None:
        return None

    span = _tracer.start_span(name, attributes=attributes)
    return span


def end_span(
    span: Any,
    status: str = "ok",
    error: str | None = None,
) -> None:
    """End a previously started span.

    Args:
        span: The span object returned by :func:`start_span`.  Passing
            ``None`` (the no-op case) is safe and does nothing.
        status: ``"ok"`` or ``"error"``.
        error: Optional error description recorded on the span when
            *status* is ``"error"``.
    """
    if span is None:
        return

    if _status_mod is not None:
        if status == "error":
            span.set_status(_status_mod.ERROR, description=error or "")
        else:
            span.set_status(_status_mod.OK)

    span.end()


@contextmanager
def trace_span(
    name: str,
    attributes: dict[str, str | int | float | bool] | None = None,
) -> Generator[Any, None, None]:
    """Context manager that wraps a block in an OTEL span.

    Usage::

        with trace_span(SPAN_EXECUTE, {"job_id": jid}) as span:
            do_work()

    If tracing is disabled the block executes normally and *span* is
    ``None``.

    On unhandled exceptions the span is ended with error status and the
    exception is re-raised.
    """
    span = start_span(name, attributes)
    try:
        yield span
    except Exception as exc:
        end_span(span, status="error", error=str(exc))
        raise
    else:
        end_span(span, status="ok")


def inject_trace_context(env: dict[str, str]) -> dict[str, str]:
    """Inject W3C ``traceparent`` into an environment dict.

    Used when launching agent containers so that the child process can
    continue the current trace.  If tracing is disabled the dict is
    returned unmodified.

    Args:
        env: Mutable mapping of environment variables for the child
            process.

    Returns:
        The same *env* dict (mutated in-place for convenience).
    """
    if _trace_mod is None:
        return env

    try:
        from opentelemetry.trace.propagation import (
            get_current_span,  # type: ignore[import-untyped]
        )

        span = get_current_span()
        ctx = span.get_span_context()
        if ctx and ctx.trace_id:
            # Build a W3C traceparent header value.
            tid = format(ctx.trace_id, "032x")
            sid = format(ctx.span_id, "016x")
            flg = format(ctx.trace_flags, "02x")
            traceparent = f"00-{tid}-{sid}-{flg}"
            env["TRACEPARENT"] = traceparent
    except (ImportError, AttributeError):
        pass

    return env
