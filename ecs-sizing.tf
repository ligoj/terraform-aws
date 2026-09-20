# Sizing profiles: var.cpu (vCPU count) is the ONLY sizing input; the task memory,
# the split between the two containers and the JVM settings derive from it.
# - ui: a small fixed JVM heap, its share only grows with the largest tasks.
# - api: gets the rest. 'memory' is the hard limit, 'memory_reservation' the soft
#   one; the heap is a percentage of the container memory (the JVM reads the cgroup
#   limit), growing with the size since the non-heap overhead stays roughly constant.
# Fargate only accepts fixed task sizes. At 32 vCPU the memory choices are 60, 120 or
# 244 GB (no 128 GB), so that profile uses 120 GB with the same 80% api ratio.
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
      task = { cpu = 32768, memory = 122880, fargate = true }
      ui   = { cpu = 1024, memory = 1024, memory_reservation = 512, java_memory = "-Xms128M -Xmx128M" }
      api = {
        cpu         = 31744, memory = 121856, memory_reservation = 97472, active_processor_count = 32
        java_memory = "-XX:InitialRAMPercentage=80 -XX:MaxRAMPercentage=80 -XX:+UseZGC"
      }
    }
  }

  sizing = local.ecs_sizing[tostring(var.cpu)]
}
