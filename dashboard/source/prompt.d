/**
 * Taskavista
 *
 * Fills in the prompts that are sent to agents.
 *
 * Authors:
 *  Mike Bierlee, m.bierlee@lostmoment.com
 * Copyright: 2026 Mike Bierlee
 * License:
 *  This software is licensed under the terms of the MIT license.
 *  The full terms of the license can be found in the LICENSE.txt file.
 */

module prompt;

import std.algorithm.searching : endsWith, startsWith;
import std.array : appender;
import std.format : format;
import std.string : KeepTerminator, lineSplitter, strip;

private enum Branch
{
    none,
    ifBranch,
    elseBranch
}

/// Fills in the prompts that are sent to agents.
class PromptParser
{
    /**
     * Fills in a prompt: first keeps or drops its `[if name]` / `[else]` / `[end]`
     * blocks, then replaces its placeholders.
     *
     * Params:
     *   prompt = The prompt's text, not the name of its file.
     *   placeholders = Each placeholder, such as "<agent name>", and its value. A
     *     placeholder in the prompt that is not a key here is left as it is.
     *   conditions = Each condition named by an `[if name]`, and whether it holds.
     *
     * Returns: The prompt with its blocks resolved and its placeholders replaced.
     *
     * Throws: `Exception` when the prompt names a condition that is not in
     *   `conditions`, or when its blocks are malformed: an `[else]` or `[end]` with
     *   no `[if]`, an `[if]` inside another, or an `[if]` with no `[end]`.
     */
    public string parse(string prompt, const string[string] placeholders, const bool[string] conditions)
    {
        return replacePlaceholders(resolveConditions(prompt, conditions), placeholders);
    }

    private string resolveConditions(string prompt, const bool[string] conditions)
    {
        auto result = appender!string;
        Branch branch = Branch.none;
        bool condition;
        size_t lineNumber;

        foreach (line; prompt.lineSplitter!(KeepTerminator.yes))
        {
            lineNumber++;
            auto marker = line.strip;

            if (marker.startsWith("[if ") && marker.endsWith("]"))
            {
                if (branch != Branch.none)
                {
                    throw new Exception(format("Line %s of the prompt: an [if] cannot be inside another.", lineNumber));
                }

                auto name = marker["[if ".length .. $ - 1].strip;
                auto value = name in conditions;
                if (value is null)
                {
                    throw new Exception(format("Line %s of the prompt: there is no condition \"%s\".",
                            lineNumber, name));
                }

                condition = *value;
                branch = Branch.ifBranch;
            }
            else if (marker == "[else]")
            {
                if (branch != Branch.ifBranch)
                {
                    throw new Exception(format("Line %s of the prompt: an [else] with no [if].", lineNumber));
                }

                branch = Branch.elseBranch;
            }
            else if (marker == "[end]")
            {
                if (branch == Branch.none)
                {
                    throw new Exception(format("Line %s of the prompt: an [end] with no [if].", lineNumber));
                }

                branch = Branch.none;
            }
            else if (branch == Branch.none || (branch == Branch.ifBranch) == condition)
            {
                result.put(line);
            }
        }

        if (branch != Branch.none)
        {
            throw new Exception("The prompt has an [if] with no [end].");
        }

        return result[];
    }

    /**
     * One pass from left to right, rather than a replace per placeholder, so that
     * a value that contains a placeholder's text, as the person's message may, is
     * put in as it is instead of being replaced in turn. Where two placeholders
     * match at the same place, the longer one wins.
     */
    private string replacePlaceholders(string text, const string[string] placeholders)
    {
        auto result = appender!string;
        size_t copiedTo;
        size_t i;

        while (i < text.length)
        {
            string match;
            foreach (key; placeholders.byKey)
            {
                if (key.length > match.length && text[i .. $].startsWith(key))
                {
                    match = key;
                }
            }

            if (match.length > 0)
            {
                result.put(text[copiedTo .. i]);
                result.put(placeholders[match]);
                i += match.length;
                copiedTo = i;
            }
            else
            {
                i++;
            }
        }

        result.put(text[copiedTo .. $]);
        return result[];
    }
}

unittest
{
    import std.exception : assertThrown;

    const string[string] noPlaceholders;
    const bool[string] noConditions;
    auto parser = new PromptParser;

    assert(parser.parse("", noPlaceholders, noConditions) == "");
    assert(parser.parse("Hello <name>.", ["<name>": "Ada"], noConditions) == "Hello Ada.");
    assert(parser.parse("<a> and <a>", ["<a>": "x"], noConditions) == "x and x");
    assert(parser.parse("Hello <name>.", noPlaceholders, noConditions) == "Hello <name>.");
    assert(parser.parse("<a><b>", ["<a>": "<b>", "<b>": "<a>"], noConditions) == "<b><a>");
    assert(parser.parse("<ab>", ["<a": "1", "<ab>": "2"], noConditions) == "2");
    assert(parser.parse("日本 <x> ü", ["<x>": "語"], noConditions) == "日本 語 ü");

    enum ifElse = "before\n[if project]\nin <project>\n[else]\nno project\n[end]\nafter\n";
    assert(parser.parse(ifElse, ["<project>": "Q3"], ["project": true]) == "before\nin Q3\nafter\n");
    assert(parser.parse(ifElse, ["<project>": "Q3"], ["project": false]) == "before\nno project\nafter\n");

    enum ifOnly = "a\n[if x]\nb\n[end]\nc";
    assert(parser.parse(ifOnly, noPlaceholders, ["x": true]) == "a\nb\nc");
    assert(parser.parse(ifOnly, noPlaceholders, ["x": false]) == "a\nc");
    assert(parser.parse("a\r\n  [if x]  \r\nb\r\n[end]\r\nc", noPlaceholders, [
                "x": true
            ]) == "a\r\nb\r\nc");
    enum twoBlocks = "[if x]\nb\n[end]\n[if y]\nc\n[else]\nd\n[end]";
    assert(parser.parse(twoBlocks, noPlaceholders, ["x": false, "y": false]) == "d\n");

    // Conditions are resolved before placeholders, so a value is never read as a marker.
    assert(parser.parse("<m>", ["<m>": "[if x]\n[end]"], noConditions) == "[if x]\n[end]");

    assertThrown(parser.parse(ifElse, noPlaceholders, noConditions));
    assertThrown(parser.parse(ifElse, noPlaceholders, ["other": true]));
    assertThrown(parser.parse("[if x]\na", noPlaceholders, ["x": true]));
    assertThrown(parser.parse("a\n[else]\nb", noPlaceholders, noConditions));
    assertThrown(parser.parse("a\n[end]", noPlaceholders, noConditions));
    assertThrown(parser.parse("[if x]\n[else]\n[else]\n[end]", noPlaceholders, [
                "x": true
            ]));
    assertThrown(parser.parse("[if x]\n[if y]\n[end]\n[end]", noPlaceholders, [
                "x": true,
                "y": true
            ]));
}
