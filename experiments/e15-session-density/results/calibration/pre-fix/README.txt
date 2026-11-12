PRE-FIX EVIDENCE -- NOT CALIBRATION. Superseded; do not use these numbers.

Default-point N=1 rungs run 2026-11-02 02:31-03:21Z with the measured library BEFORE the replay fix
(ffd03c8, 6f344a8): the driver sent every library invocation of a call as its own Exec, so the SBX
arm paid one VM lifecycle per invocation (2.43 Execs per call in this window; 7.86 corpus-wide with
the measured library, 3.57 with nominal). sbx N=1 did not hold (median pace +12.56% > 10%); this is
the Task 8 BLOCKED finding. resident-inf N=1 held. Driver binary and library hashes are in each
params.json/record.json.

Also superseded by abdff01/9c9a385 (grouped invocation order).
