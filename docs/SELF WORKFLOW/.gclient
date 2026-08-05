solutions = [
  {
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "name": "src",
    "custom_deps": {
        "src/third_party/depot_tools": None,
        "src/third_party/espresso": None,
        "src/third_party/netty-tcnative/src": None,
        "src/third_party/netty4/src": None,
        "src/tools/luci-go": None,
        "src/chrome/test/data/xr/webvr_info": None,
        "src/third_party/quic_trace/src": None,
        "src/third_party/webgl/src": None,
        "src/third_party/hunspell_dictionaries": None,
        "src/third_party/apache-portable-runtime/src": None,
        "src/third_party/requests/src": None,
        "src/third_party/libFuzzer/src": None,
        "src/third_party/libprotobuf-mutator/src": None,
        "src/third_party/webdriver/pylib": None,
        "src/chrome/test/data/perf/canvas_bench": None,
        "src/chrome/test/data/perf/frame_rate/content": None,
    },
    "custom_vars": {
        "checkout_configuration": "small",
        "checkout_telemetry_dependencies": False,
    },
  },
]
target_os = ["android"]
target_os_only = False
