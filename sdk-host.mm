#import <Cocoa/Cocoa.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

// Folder (next to the host app) holding the platform-patched RiotGamesApi.framework.
#ifndef SDK_DIR
#define SDK_DIR "sdk-windows-override-arm64"
#endif

static std::string resolvedPath(const std::string &path) {
    return [[NSString stringWithUTF8String:path.c_str()]
        stringByResolvingSymlinksInPath].fileSystemRepresentation;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        // Everything lives next to "TFT SDK Host*.app", so the project folder can be moved.
        NSString *bundle = NSBundle.mainBundle.bundlePath.stringByResolvingSymlinksInPath;
        const std::string root = bundle.stringByDeletingLastPathComponent.fileSystemRepresentation;
        const std::string sdkPath = root + "/" SDK_DIR "/RiotGamesApi.framework/RiotGamesApi";
        std::string riotApp = root + "/Riot Runtime.app";
        if (![NSFileManager.defaultManager fileExistsAtPath:[NSString stringWithUTF8String:riotApp.c_str()]]) {
            riotApp = root + "/Riot Windows Auth Test.app";
        }
        const std::string foundationPath = riotApp + "/Contents/Frameworks/libRiotClientFoundation.dylib";
        const std::string data = resolvedPath(root + "/sdk-host-data");

        if (!dlopen(sdkPath.c_str(), RTLD_NOW | RTLD_GLOBAL)) {
            std::fprintf(stderr, "SDK load failed: %s\n", dlerror());
            return 1;
        }
        void *foundation = dlopen(foundationPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (!foundation) {
            std::fprintf(stderr, "Foundation load failed: %s\n", dlerror());
            return 1;
        }
        auto run = reinterpret_cast<int (*)(int, char **)>(dlsym(foundation, "Run"));
        if (!run) {
            std::fprintf(stderr, "Foundation Run entry point missing\n");
            return 1;
        }
        if (argc == 3 && std::string(argv[1]) == "--check-sdk") {
            const unsigned long long address = std::strtoull(argv[2], nullptr, 16);
            for (uint32_t index = 0; index < _dyld_image_count(); ++index) {
                if (std::string(_dyld_get_image_name(index)).find("RiotGamesApi.framework/RiotGamesApi") != std::string::npos) {
                    auto getter = reinterpret_cast<const char *(*)()>(
                        reinterpret_cast<uintptr_t>(_dyld_get_image_header(index)) + address);
                    const char *platform = getter();
                    std::printf("%s\n", platform);
                    return std::string(platform) == "windows" ? 0 : 1;
                }
            }
            return 1;
        }
        static std::vector<std::string> settings = {
            "--disable-launch-agent",
            "--app-root=" + riotApp,
            "--user-data-root=" + data + "/user",
            "--data-root=" + data + "/shared",
            "--log-root=" + data + "/logs",
            "--update-root=" + data + "/update",
            "--system-yaml-override=" + resolvedPath(root + "/sdk-host-system.yaml"),
            "--persistence-path=" + data + "/sdk",
            "--client-config-override-file=" + resolvedPath(root + "/riot-sdk-host-override.json"),
        };
        NSString *regionPath = [NSString stringWithUTF8String:(root + "/riot-region.txt").c_str()];
        NSString *region = [[NSString stringWithContentsOfFile:regionPath encoding:NSUTF8StringEncoding error:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (region.length) settings.push_back("--region=" + std::string(region.UTF8String));
        std::vector<char *> arguments(argv, argv + argc);
        for (std::string &setting : settings) arguments.push_back(setting.data());
        arguments.push_back(nullptr);
        [NSApplication sharedApplication];
        return run(static_cast<int>(arguments.size()) - 1, arguments.data());
    }
}
