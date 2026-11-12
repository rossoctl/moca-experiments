# project/tests is the workload's own suite (the py_test command); test_workload.py runs it through
# the library's command, so `pytest e17` does not collect it a second time at full scale.
collect_ignore = ["project"]
