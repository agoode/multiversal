#include "HeaderParser.hpp"
#include <iostream>
#include <regex>
#include <vector>
#include <unordered_set>
#include <stdio.h>
#include "yaml-cpp/yaml.h"

extern std::vector<YAML::Node> things;
extern std::unordered_map<std::string, int> names;


class SpecialStyle
{
    std::regex regex;
    std::function<void (YAML::Emitter&)> fun;
public:
    template<typename T>
    SpecialStyle(std::string s, T manip)
    {
        regex = std::regex(s);
        fun = [manip](YAML::Emitter& yamlout) { yamlout << manip; };
    }

    void apply(YAML::Emitter& yamlout, const std::string& path) const
    {
        if(std::regex_match(path, regex))
            fun(yamlout);
    }
};

const std::vector<SpecialStyle> specialStyles =
{
    { ".*/comment", YAML::Literal },
    { ".*/code", YAML::Literal }
};

void output(YAML::Emitter& yamlout, const YAML::Node& node, std::string path)
{
    if(node.IsSequence())
    {
        yamlout << YAML::BeginSeq;

        for(const auto& x : node)
            output(yamlout, x, path);

        yamlout << YAML::EndSeq;
    }
    else if(node.IsMap())
    {
        yamlout << YAML::BeginMap;
        for(const auto& entry : node)
        {
            const auto& key = entry.first;
            const auto& value = entry.second;
            yamlout << key;
            output(yamlout, value, path + "/" + key.as<std::string>());
        }
        yamlout << YAML::EndMap;
    }
    else
    {
        for(const auto& s : specialStyles)
            s.apply(yamlout, path);
        yamlout << node;
    }
    
}

extern FILE *yyin;

int main(int argc, char *argv[])
{
    YAML::Node override;
    bool haveOverride = false;
    try
    {
        override = YAML::LoadFile(argv[2]);
        haveOverride = true;
    }
    catch(YAML::BadFile)
    {
    }

    yyin = fopen(argv[1], "r");
    yy::HeaderParser parser;

    parser.parse();
    YAML::Emitter yamlout;


    std::unordered_set<std::string> overriddenNames;

    if(haveOverride)
    {
        for(const auto& thing : override)
        {
            std::string name;
            for(auto n : thing)
            {
                if(n.second.IsMap() && n.second["name"])
                    name = n.second["name"].as<std::string>();
            }
            if(!name.empty())
                overriddenNames.insert(name);
        }
    }

    yamlout << YAML::BeginSeq;
    bool first = true;
    for(const auto& thing : things)
    {
        std::string name;
        for(auto n : thing)
        {
            if(n.second.IsMap() && n.second["name"])
                name = n.second["name"].as<std::string>();
        }

        if(!name.empty() && overriddenNames.find(name) != overriddenNames.end())
            continue;

        if(!first)
            yamlout << YAML::Newline << YAML::Newline << YAML::Comment("####") << YAML::Newline;
        first = false;
        output(yamlout, thing, "");
    }

    if(haveOverride)
    {
        for(const auto& thing : override)
        {
            yamlout << YAML::Newline << YAML::Newline << YAML::Comment("####") << YAML::Newline;
            output(yamlout, thing, "");
        }
    }
    yamlout << YAML::EndSeq;

    std::cout << yamlout.c_str() << std::endl;


    return 0;
}