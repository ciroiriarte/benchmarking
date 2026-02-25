# Objective
* This repository contains benchmark scripts for infrastructure with synthetic tests
* The scripts should configure the pre-requisites in the target machine, run the tests and collect/secure resulting files
* Test should be reproducible & auditable

# Functional requirements
* Scripts should assess performance in one dimension each (CPU bound or I/O bound workloads)
* Scripts should accept test naming as a parameter to later compare several runs.
* CPU testing script should use Phoronix Test Suite CPU tests.
* For Storage tests, PTS should also be used with all the permutations that would allow evaluating latency & performance of different disk configurations. IOPS & Throughput results should be supported with workload characterization (read/write ratio, block size, access pattern, etc)
* When more than one test disk is provided (with different characteristics), tests must be executed sequentially (not in parallel). This means that a single VM with N disks of different characteristics should execute tests on disk A, when it finishes, move to disk B and so on.
* Results should be optionally uploaded to OpenBenchmarking.org
* Benchmark framework (scripts, tooling and setup documentation) must support different Linux distributions: openSUSE, Ubuntu, Debian, Rocky Linux.
* Scripts should work on virtual or physical machines.
* Both the system snapshot and the PTS test results should be copied to the benchmark-results/${EXECUTIONID} directory in the same path each script is executed from. Owner of the directory and files should be the user we're using to start the script, not root.

# Coding style
* Functions must be used when code becomes too large/complex.
* Magic numbers should be avoided. Properly documented variables should be used instead.
* Scripts requiring input should fail with a usage guide when parameters are missing.
* Bash should be used to its full capabilities before introducing additional dependencies.
* All scripts should have inline documentation.

# Best Practices
* Benchmark tests execution should be auditable and reproducible
* Follow Brendan Gregg's best practices:
 https://www.brendangregg.com/methodology.html
 https://www.brendangregg.com/usemethod.html
 https://www.brendangregg.com/tsamethod.html
 https://www.brendangregg.com/offcpuanalysis.html
 https://www.brendangregg.com/activebenchmarking.html
* Nutanix performance test methodology:
 https://portal.nutanix.com/page/documents/kbs/details?targetId=kA07V000000LX7xSAG

# Documentation
* Should include scripts usage guidance.
* Should include OS preparation steps
* For virtual machines, should include test scenario setup procedures (vSphere or Openstack)
* README.md must track code functionality

# Live testing
* testing of the script is possible connecting via SSH to test nodes.
* openSuSE test node available at cloudadmin@192.168.56.101
* Ubuntu test node available at cloudadmin@192.168.56.102
* Rocky Linux test node available at cloudadmin@192.168.56.103
* updated script should be copied to the test machine and executed there.
* authentication will be solved for you via SSH public/private keys
* sudo is passwordless
* don't ask for confirmation of connection or command execution to/at the test machine
