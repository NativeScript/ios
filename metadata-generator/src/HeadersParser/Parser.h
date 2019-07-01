#pragma once

#include <string>
#include <vector>

std::vector<std::string> parsePaths(std::string& paths);

std::string CreateUmbrellaHeader(const std::vector<std::string>& clangArgs, std::vector<std::string>& includePaths);
