#pragma once

#include <cstdio>
#include <cerrno>
#include <fcntl.h>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

inline bool writeLogBytes(int file, const char *bytes, size_t length) {
    while (length) {
        const ssize_t written = write(file, bytes, length);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return false;
        bytes += written;
        length -= written;
    }
    return true;
}

// The sidecar lock serializes writers even when the current file is renamed.
inline bool appendRotatingLog(const std::string &path, const char *bytes, size_t length,
                              size_t limit = 10 * 1024 * 1024) {
    int lock = open((path + ".lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock < 0) return false;
    if (flock(lock, LOCK_EX) != 0) { close(lock); return false; }
    int file = open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    bool success = file >= 0;
    struct stat info = {};
    if (success) success = fstat(file, &info) == 0;
    if (success && info.st_size > static_cast<off_t>(limit)) {
        std::vector<char> tail(limit);
        const ssize_t count = pread(file, tail.data(), tail.size(), info.st_size - limit);
        success = count == static_cast<ssize_t>(limit) && ftruncate(file, 0) == 0
                  && writeLogBytes(file, tail.data(), tail.size());
        info.st_size = limit;
    }
    if (success && info.st_size + length > limit) {
        close(file);
        file = -1;
        for (int archive = 3; archive >= 1; --archive) {
            const std::string source = archive == 1 ? path : path + "." + std::to_string(archive - 1);
            const std::string destination = path + "." + std::to_string(archive);
            if (rename(source.c_str(), destination.c_str()) != 0 && errno != ENOENT) success = false;
        }
        if (success) file = open(path.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
        success = success && file >= 0;
    }
    if (success) success = lseek(file, 0, SEEK_END) >= 0 && writeLogBytes(file, bytes, length);
    if (file >= 0) close(file);
    flock(lock, LOCK_UN);
    close(lock);
    return success;
}
