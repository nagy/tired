# Spend the budget of each idle job, not of the head job

One idle queue serves directory size walks and element counts, and each
kind carries its own budget option.  A pass used to read the budget of
the head job alone and turn it into one deadline for the whole queue.
So an element count ran under the 0.2 second size budget, a size walk
ran under the 0.02 second element budget, and a head job with a nil
budget left the pass unbounded even when every later job named a
budget.  The two options therefore described nothing that the queue
did.

The pass now adds the seconds that each step took and stops a job when
its own budget is spent.  A nil budget runs that job until it ends and
bounds no other job, and `input-pending-p' still stops the whole pass at
the next step.  A mixed pass can spend the sum of both budgets, about
0.22 seconds by default, and that is the price of one documented rule
instead of a head-dependent one.

One queue-wide deadline was the alternative: it is cheaper and simpler,
but the size option would shorten an element pass and the element
option would shorten a size pass, so neither option would keep its
promise.  Separate passes per kind were the second alternative, and
they need two schedules and a rule for which kind runs first.  A round
that spends no step ends the pass, so a budget of zero cannot spin.
