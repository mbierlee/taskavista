module helpers;

import std.algorithm : all, any, canFind, splitter;
import std.array : replace;
import std.ascii : isDigit;
import std.format : format;
import std.uni : NFC, isAlpha, isMark, isNumber, normalize, toLower;

/**
 * Whether `value` is a slug: words of lowercase letters, digits and the
 * marks that go with them, in any script, joined by single hyphens and in
 * NFC, as `slugify` makes them. The slug check constraint in sql/init.sql
 * cannot say "letter" for every script, so it only checks the shape.
 */
bool isSlug(string value) @safe pure
{
    return value.length > 0 && value.normalize!NFC == value
        && value.splitter('-')
        .all!(word => word.length > 0
                && word.all!(c => c.isWordChar && c.toLower == c));
}

/**
 * Lowercases `name` and joins its runs of letters, digits and marks, in any
 * script, with single hyphens: "Q3 finance" becomes "q3-finance" and
 * "Café Ü" becomes "café-ü". Anything else is dropped as a separator, so the
 * result can be empty. NFC, so that a name typed with a combining accent and
 * one typed with an accented letter make the same slug.
 */
string slugify(string name) @safe pure
{
    string slug;
    bool gap;

    foreach (dchar c; name.toLower.normalize!NFC)
    {
        if (c.isWordChar)
        {
            if (gap && slug.length > 0)
            {
                slug ~= '-';
            }
            slug ~= c;
            gap = false;
        }
        else
        {
            gap = true;
        }
    }

    return slug;
}

/**
 * Whether `name` has a letter or digit in it, in any script, which is what
 * the name check constraint in sql/init.sql asks of a project's name. A
 * mark alone does not count: it belongs to a letter.
 */
bool hasLetterOrDigit(string name) @safe pure
{
    return name.any!(c => (c.isAlpha && !c.isMark) || c.isNumber);
}

private bool isWordChar(dchar c) @safe pure
{
    return c.isAlpha || c.isNumber || c.isMark;
}

unittest
{
    assert(slugify("Q3 finance") == "q3-finance");
    assert(slugify("  Website -- relaunch! ") == "website-relaunch");
    assert(slugify("Café") == "café");
    assert(slugify("Cafe\u0301") == "café");
    assert(slugify("日本 プロジェクト") == "日本-プロジェクト");
    assert(slugify("हिन्दी") == "हिन्दी");
    assert(slugify("ΕΛΛΗΝΙΚΑ.v2") == "ελληνικα-v2");
    assert(slugify("!!!") == "");
    assert(slugify("a ✓ b") == "a-b");

    assert(isSlug("q3-finance"));
    assert(isSlug("café"));
    assert(isSlug("日本-プロジェクト"));
    assert(isSlug("हिन्दी"));
    assert(!isSlug(""));
    assert(!isSlug("-a"));
    assert(!isSlug("a--b"));
    assert(!isSlug("Q3"));
    assert(!isSlug("Café"));
    assert(!isSlug("cafe\u0301"));
    assert(!isSlug("a.b"));
    assert(!isSlug("a/b"));

    assert(hasLetterOrDigit("日本"));
    assert(hasLetterOrDigit("٣"));
    assert(!hasLetterOrDigit("!!!"));
    assert(!hasLetterOrDigit("— ✓ —"));
    assert(!hasLetterOrDigit("\u0301"));
}

/**
 * Whether `value` passes the color check constraint in sql/init.sql:
 * ^#[0-9a-f]{6}$
 */
bool isHexColor(string value) @safe pure
{
    return value.length == 7 && value[0] == '#'
        && value[1 .. $].all!(c => c.isDigit || (c >= 'a' && c <= 'f'));
}

unittest
{
    assert(isHexColor("#8fa6ff"));
    assert(isHexColor("#000000"));
    assert(!isHexColor("#8FA6FF"));
    assert(!isHexColor("#fff"));
    assert(!isHexColor("8fa6ff0"));
    assert(!isHexColor("#8fa6fg"));
    assert(!isHexColor(""));
}

/**
 * Single-quotes a value for a libpq connection string, escaping backslashes
 * and quotes.
 */
string quoted(string value)
{
    return "'" ~ value.replace(`\`, `\\`).replace("'", `\'`) ~ "'";
}

/// Formats a base URL, wrapping IPv6 addresses in brackets.
string formatURL(string address, ushort port)
{
    return address.canFind(':')
        ? format("http://[%s]:%s/", address, port) : format("http://%s:%s/", address, port);
}
