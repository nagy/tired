# Drive the idle queue from a normal timer

ADR 0017 put the size walk and the element counts on one idle queue
and gave every pass a successor idle timer, because an idle timer
fires once for one transition into the idle state.  That successor
used a delay of zero, so the timer was ripe again the moment the pass
returned.

A ripe idle timer stops the read loop of Emacs before the wait that
reads subprocess output.  While the queue held work, Emacs never read
that output, so no filter ran and no sentinel ran.  Measured on Emacs
31.1 with a chain of 0.2 s passes: a child that writes one second
after `start-process` reached its filter at 5.0 s, and only because a
key arrived then.  The same child reached its filter at 1.03 s with no
chain at all.  A larger idle delay does not help, because idle time
accrues while a timer runs: 0.01 s, 0.2 s, 0.5 s and 3 s steps starved
alike.

The queue now chains a normal timer through `tired--queue-delay`,
0.02 seconds, and `tired--queue-wake` gates the pass on
`input-pending-p`.  A normal timer fires in the wait for input, so
that wait still reads process output between two passes.  Measured:
the same child reached its filter at 1.03 s with the chain running.
On a real listing of 200 000 names the child reached its filter
1.1 s after its start, against 3.2 s with the old chain.

A window manager that runs inside Emacs shows the reach of the
starvation.  EXWM reaches X through xelb, and xelb reads the X socket
with one process filter, `xcb:-connection-filter'.  That filter
queues an event and then runs its listeners through
`xcb:-process-events', so `exwm-manage--on-MapRequest' and the
`MapWindow' request of `exwm-manage--manage-window' run inside the
filter alone.  While the chain stayed ripe, a `MapRequest' waited in
the socket, the client stayed unmapped, and no placement step ran.
The external program had started, because `start-process' forks at
once, and the user saw no window.

A repeating idle timer does not show the defect.  Measured with a
callback that spends 0.2 s: `run-with-idle-timer' with a repeat
argument fired twice in four seconds and read process output on time,
because the timer machinery sets the next ripe time in the future.
Only a timer that a Lisp callback arms again from inside itself goes
ripe at once, and the queue did exactly that.

## Considered options

Keep the idle timer and stop the chain while a process is live.  Tired
cannot tell a process that the user waits for from a long-lived one,
such as a language server, so the walk would stop for hours.

Run the walk from a `make-thread` worker.  ADR 0017 measured Emacs
threads as no answer, and ADR 0029 repeated the measurement.

Chain a normal timer with no gate.  A normal timer also fires while
Emacs reads a command, so a pass would compete with a keystroke for up
to `tired-directory-size-budget`.  The gate costs one
`input-pending-p` call per wake and keeps the old policy.

## Consequences

The queue holds one timer of a new kind, and a test names it.  A wake
with input pending arms itself again instead of stepping a job, so a
user who types costs one timer per 0.02 seconds and no file read.  The
starvation was never specific to a size walk: every element count
waiting on the queue starved every subprocess the same way, so the
repair reaches both kinds.
