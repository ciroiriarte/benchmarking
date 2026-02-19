# Objective
* This repository contains benchmark scripts for infrastructure with synthetic tests

# Functional requirements
* Scripts should assess performance in one dimension each (CPU bound or I/O bound workloads)
* Scripts should accept test naming as a parameter to later compare several runs.
* CPU testing script should use Phoronix Test Suite CPU tests.
* For Storage tests, PTS should also be used with all the permutations that would allow evaluating latency & performance of different disk configurations. IOPS & Throughput results should be supported with workload characterization (read/write ratio, block size, access pattern, etc)
* When more than one test disk is provided (with different characteristics), tests must be executed sequentially (not in parallel). This means that a single VM with N disks of different characteristics should execute tests on disk A, when it finishes, move to disk B and so on.
* Results should be optionally uploaded to OpenBenchmarking.org
* Benchmark framework (scripts, tooling and setup documentation) must support different Linux distributions: openSUSE, Ubuntu, Debian, Rocky Linux.
* Scripts should work on virtual or physical machines.

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

# Documentation
* Should include scripts usage guidance.
* Should include OS preparation steps
* For virtual machines, should include test scenario setup procedures (vSphere or Openstack)
* README.md must track code functionality
