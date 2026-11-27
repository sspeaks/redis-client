"""Tokenize Haskell and split it into top-level declarations.

Nothing is compiled, so code under review never runs. Constructs whose meaning
cannot be read from source (CPP, declaration splices, ...) raise SourceError.
"""

import re
import unicodedata
from collections import namedtuple


class SourceError(Exception):
    pass


Token = namedtuple("Token", "kind text line column")

IDENT = r"[^\W\d][\w']*"
QUALIFIED = re.compile(rf"(?:[A-Z][\w']*\.)*{IDENT}#*")
QUALIFIED_OPERATOR = re.compile(r"(?:[A-Z][\w']*\.)+[!#$%&*+./<=>?@\\^|~:\-]+")
OPERATOR = re.compile(r"[!#$%&*+./<=>?@\\^|~:\-]+")
NUMBER = re.compile(r"\d[\w]*(?:\.\d\w*)?")
CHAR = re.compile(r"'(?:[^'\\\n]|\\(?:[A-Z]+[0-9]?|\^.|\d+|x[0-9a-fA-F]+|o[0-7]+|.))'")
QUASI_QUOTE = re.compile(r"\[[a-z_][\w'.]*\|[^|]")
COMMENT = re.compile(r"--+(?![!#$%&*+./<=>?@\\^|~:])")


def tokenize(text):
    if re.search(r"[﻿\t\f\r\v]", text):
        raise SourceError("tabs and control characters are not supported")
    position, line, start, tokens = 0, 1, 0, []
    while position < len(text):
        char = text[position]
        if char == "\n":
            position, line = position + 1, line + 1
            start = position
            continue
        if char.isspace():
            position += 1
            continue
        column, first_line = position - start, line
        if char == "#" and column == 0:
            raise SourceError(f"line {line}: preprocessor directive")
        if text.startswith("{-", position):
            begin, depth = position, 0
            while True:
                if text.startswith("{-", position):
                    depth, position = depth + 1, position + 2
                elif text.startswith("-}", position):
                    depth, position = depth - 1, position + 2
                    if not depth:
                        break
                elif position >= len(text):
                    raise SourceError("unterminated comment")
                else:
                    if text[position] == "\n":
                        line, start = line + 1, position + 1
                    position += 1
            block = text[begin:position]
            if block.startswith("{-#"):
                if not block.endswith("#-}") or "{-" in block[2:]:
                    raise SourceError(f"line {first_line}: unsupported pragma")
                tokens.append(Token("pragma", " ".join(block.split()), first_line, column))
            continue
        match = COMMENT.match(text, position)
        if match:
            following = text[match.end() : match.end() + 1]
            if not following.isascii() and unicodedata.category(following)[0] in "SP":
                # GHC lexes this as an operator, not as a comment.
                raise SourceError(f"line {line}: unsupported unicode operator")
            end = text.find("\n", position)
            position = len(text) if end < 0 else end
            continue
        if text.startswith('"""', position) or QUASI_QUOTE.match(text, position):
            # [x|x <- xs] without spaces also lands here; rejecting it is safe.
            raise SourceError(f"line {line}: quasi-quote or multiline string")
        if char == '"':
            begin = position
            position += 1
            while position < len(text) and text[position] != '"':
                if text[position] == "\\" and text[position + 1 : position + 2].isspace():
                    end = text.find("\\", position + 1)
                    if end < 0 or text[position + 1 : end].strip():
                        raise SourceError("bad string gap")
                    if "\n" in text[position:end]:
                        line += text.count("\n", position, end)
                        start = text.rfind("\n", position, end) + 1
                    position = end + 1
                elif text[position] == "\n":
                    raise SourceError(f"line {line}: unterminated string")
                else:
                    position += 2 if text[position] == "\\" else 1
            position += 1
            if position > len(text):
                raise SourceError("unterminated string")
            tokens.append(Token("string", text[begin:position], first_line, column))
            continue
        for kind, pattern in (
            ("char", CHAR),
            ("operator", QUALIFIED_OPERATOR),
            ("ident", QUALIFIED),
            ("number", NUMBER),
            ("operator", OPERATOR),
        ):
            match = pattern.match(text, position)
            if match:
                position = match.end()
                break
        else:
            kind = "punct"
            if char not in "()[]{},;`'":
                raise SourceError(f"line {line}: unexpected character {char!r}")
            position += 1
        tokens.append(Token(kind, text[start + column : position], line, column))
    return tokens


def render(tokens):
    return " ".join(token.text for token in tokens)


def chunks(tokens):
    """Split tokens wherever one starts in column zero."""
    result = []
    for token in tokens:
        if token.column == 0 or not result:
            result.append([])
        result[-1].append(token)
    return result


def depth_zero(tokens):
    """Yield (index, token) outside brackets, including the brackets themselves."""
    depth = 0
    for index, token in enumerate(tokens):
        if token.kind == "punct" and token.text in ")]}":
            depth -= 1
        if depth < 0:
            raise SourceError(f"line {token.line}: unbalanced brackets")
        if depth == 0:
            yield index, token
        if token.kind == "punct" and token.text in "([{":
            depth += 1
    if depth:
        raise SourceError("unbalanced brackets")


def split_commas(tokens):
    parts, last = [], 0
    for index, token in depth_zero(tokens):
        if token.text == ",":
            parts.append(tokens[last:index])
            last = index + 1
    parts.append(tokens[last:])
    return [part for part in parts if part]


def closing(tokens, start):
    """Index of the bracket that closes the one at start."""
    for index, token in depth_zero(tokens[start:]):
        if index and token.text in (")", "]", "}"):
            return start + index
    raise SourceError("unbalanced brackets")
