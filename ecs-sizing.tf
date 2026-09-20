# Sizing profiles: var.cpu (vCPU count) is the ONLY sizing input; the task memory,
# the split between the two containers and the JVM settings derive from it.
# - ui: a small fixed JVM heap, its share only grows with the largest tasks.
# - api: gets the rest. 'memory' is the hard limit, 'memory_reservation' the soft
#   one; the heap is a percentage of the container memory (the JVM reads the cgroup
#   limit), growing with the size since the non-heap overhead stays roughly constant.
# The 32 vCPU profile exceeds Fargate (16 vCPU / 120 GB max) and is rejected by the
# variable validation: kept as the reference for an EC2-backed capacity provider.
locals {
  ecs_sizing = {
    "2" = {
      task = { cpu = 2048, memory = 4096, fargate = true }
      ui   = { cpu = 256, memory = 768, memory_reservation = 512, java_memory = "-Xms128M -Xmx128M" }
      api = {
        cpu         = 1792, memory = 3328, memory_reservation = 2624, active_processor_count = 2
        java_memory = "-XX:InitialRAMPercentage=70 -XX:MaxRAMPercentage=70 -XX:+UseG1GC"
      }
    }
    "4" = {
      task = { cpu = 4096, memory = 16384, fargate = true }
      ui   = { cpu = 256, memory = 768, memory_reservation = 512, java_memory = "-Xms128M -Xmx128M" }
      api = {
        cpu         = 3840, memory = 15616, memory_reservation = 12480, active_processor_count = 4
        java_memory = "-XX:InitialRAMPercentage=75 -XX:MaxRAMPercentage=75 -XX:+UseG1GC"
      }
    }
    "8" = {
      task = { cpu = 8192, memory = 32768, fargate = true }
      ui   = { cpu = 512, memory = 1024, memory_reservation = 512, java_memory = "-Xms128M -Xmx128M" }
      api = {
        cpu         = 7680, memory = 31744, memory_reservation = 25344, active_processor_count = 8
        java_memory = "-XX:InitialRAMPercentage=80 -XX:MaxRAMPercentage=80 -XX:+UseG1GC"
      }
    }
    "16" = {
      task = { cpu = 16384, memory = 65536, fargate = true }
      ui   = { cpu = 512, memory = 1024, memory_reservation = 512, java_memory = "-Xms128M -Xmx128M" }
      api = {
        cpu         = 15872, memory = 64512, memory_reservation = 51584, active_processor_count = 16
        java_memory = "-XX:InitialRAMPercentage=80 -XX:MaxRAMPercentage=80 -XX:+UseZGC"
      }
    }
    "32" = {
      task = { cpu = 32768, memory = 131072, fargate = false }
      ui   = { cpu = 1024, memory = 1024, memory_reservation = 512, java_memory = "-Xms128M -Xmx128M" }
      api = {
        cpu         = 31744, memory = 130048, memory_reservation = 104000, active_processor_count = 32
        java_memory = "-XX:InitialRAMPercentage=80 -XX:MaxRAMPercentage=80 -XX:+UseZGC"
      }
    }
  }

  sizing = local.ecs_sizing[tostring(var.cpu)]
}
