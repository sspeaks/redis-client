"""Compute and compare the public API of the Haskell libraries from source.

The surface is deliberately over-approximate: anything that might be visible to
a library user is part of it, and any edit to an existing part is breaking.
Only pure additions are compatible. What cannot be understood raises ApiError.
"""

import re
from collections import namedtuple

import cabal_file
from haskell_source import (
    SourceError,
    chunks,
    closing,
    depth_zero,
    render,
    split_commas,
    tokenize,
)


class ApiError(Exception):
    pass


Import = namedtuple("Import", "module alias qualified hiding entries text")
Entry = namedtuple("Entry", "name namespace subs text")

# Extensions that cannot change the meaning of a declaration's source text.
NEUTRAL_EXTENSIONS = frozenset(
    "BangPatterns BlockArguments LambdaCase MultiWayIf NamedFieldPuns NumericUnderscores "
    "OverloadedStrings RecordWildCards ScopedTypeVariables TupleSections ViewPatterns".split()
)
FORBIDDEN_OPTIONS = re.compile(r"-F\b|-pgm|-cpp|-XCPP|-XTemplateHaskell|plugin|-opt")
FORBIDDEN_EXTENSIONS = frozenset({"CPP", "QuasiQuotes", "RebindableSyntax", "NoImplicitPrelude"})
IGNORED_PRAGMAS = frozenset(
    "INLINE NOINLINE INLINABLE INLINEABLE OPAQUE SPECIALIZE SPECIALISE SCC".split()
)
PRELUDE = frozenset(
    "Bool Char Double Either Float Int Integer Maybe Ordering Rational String Word IO FilePath "
    "IOError ShowS ReadS Show Read Eq Ord Enum Bounded Num Real Integral Fractional Floating "
    "RealFrac RealFloat Functor Applicative Monad MonadFail Foldable Traversable Semigroup Monoid "
    "True False Just Nothing Left Right LT EQ GT".split()
)
EXPOSING_DERIVATIONS = frozenset({"Generic", "Generic1", "Data", "Lift"})


def is_upper(token):
    return token.kind == "ident" and token.text[0].isupper()


def base_name(text):
    return re.split(r"\.(?=[^.])", text)[-1] if text[0].isupper() else text


def is_upper_name(text):
    return base_name(text)[0].isupper()


def parse_entries(tokens):
    entries = []
    for part in split_commas([t for t in tokens if t.kind != "pragma"]):
        text, namespace = render(part), ""
        if part[0].text in ("pattern", "type", "module") and len(part) > 1:
            namespace, part = part[0].text, part[1:]
        if part[0].text == "(":
            end = closing(part, 0)
            if end != 2:
                raise SourceError(f"line {part[0].line}: cannot parse export {text}")
            name, rest = part[1].text, part[3:]
        else:
            if part[0].kind != "ident":
                raise SourceError(f"line {part[0].line}: cannot parse export {text}")
            name, rest = part[0].text, part[1:]
        subs = None
        if rest:
            if rest[0].text != "(" or closing(rest, 0) != len(rest) - 1:
                raise SourceError(f"line {part[0].line}: cannot parse export {text}")
            inner = rest[1:-1]
            if len(inner) == 1 and inner[0].text == "..":
                subs = ".."
            else:
                subs = tuple(
                    sorted(t.text for t in inner if t.kind in ("ident", "operator"))
                )
        entries.append(Entry(name, namespace, subs, text))
    return entries


def parse_import(chunk):
    words = [t for t in chunk[1:] if t.kind != "pragma"]
    qualified, alias, hiding, entries = False, None, False, None
    if words and words[0].text == "safe":
        words = words[1:]
    if words and words[0].text == "qualified":
        qualified, words = True, words[1:]
    if words and words[0].kind == "string":
        raise SourceError(f"line {chunk[0].line}: package imports are not supported")
    if not words or not is_upper(words[0]):
        raise SourceError(f"line {chunk[0].line}: cannot parse import")
    module, words = words[0].text, words[1:]
    if words and words[0].text == "qualified":
        qualified, words = True, words[1:]
    if len(words) > 1 and words[0].text == "as":
        alias, words = words[1].text, words[2:]
    if words and words[0].text == "hiding":
        hiding, words = True, words[1:]
    if words:
        if words[0].text != "(" or closing(words, 0) != len(words) - 1:
            raise SourceError(f"line {chunk[0].line}: cannot parse import")
        entries = parse_entries(words[1:-1])
    elif hiding:
        raise SourceError(f"line {chunk[0].line}: cannot parse import")
    return Import(module, alias or module, qualified, hiding, entries, render(chunk))


def body_items(body):
    """Split a layout block (the tokens after `where`) into its items."""
    if not body:
        return []
    if body[0].text == "{":
        raise SourceError(f"line {body[0].line}: explicit braces are not supported")
    column, items = body[0].column, []
    for index, token in enumerate(body):
        new_line = index == 0 or token.line != body[index - 1].line
        if new_line and token.column < column:
            raise SourceError(f"line {token.line}: unexpected layout")
        if index == 0 or (new_line and token.column == column):
            items.append([])
        items[-1].append(token)
    return items


def split_where(chunk):
    for index, token in depth_zero(chunk):
        if token.text == "where":
            return chunk[:index], chunk[index + 1 :]
    return chunk, []


def first_at_depth_zero(tokens, *texts):
    for index, token in depth_zero(tokens):
        if token.text in texts and token.kind in ("operator", "ident"):
            return index
    return None


def signature_names(tokens):
    """Names declared by `a, (+) :: type`, or None when this is no signature."""
    index = first_at_depth_zero(tokens, "::", "=", "|")
    if not index or tokens[index].text != "::":
        return None
    names = []
    for part in split_commas(tokens[:index]):
        if len(part) == 1 and part[0].kind == "ident":
            names.append(part[0].text)
        elif len(part) == 3 and part[0].text == "(" and part[1].kind == "operator":
            names.append(part[1].text)
        else:
            return None
    return names


def binding_name(item):
    index = first_at_depth_zero(item, "=", "|")
    if index is None:
        return None
    left = item[:index]
    if left and left[0].text == "(" and len(left) > 2 and left[1].kind == "operator":
        return left[1].text
    for _, token in depth_zero(left):
        if token.kind == "operator" and token.text not in ("!", "~", "@"):
            return token.text
    tick = next((i for i, t in enumerate(left) if t.text == "`"), None)
    if tick is not None:
        return left[tick + 1].text
    return left[0].text


def declared_head(tokens):
    """Name and parameters of a data/type/class head, after any context."""
    arrow = first_at_depth_zero(tokens, "=>")
    if arrow is not None:
        tokens = tokens[arrow + 1 :]
    while tokens and tokens[0].kind == "pragma":
        tokens = tokens[1:]
    if not tokens or not is_upper(tokens[0]):
        raise SourceError("infix or unsupported type declaration")
    return tokens[0].text, tokens[1:]


def instance_shape(tokens):
    """(class, outermost constructor per argument or "", has an overlap pragma)."""
    flagged = any(
        t.kind == "pragma" and re.search("OVERLAP|INCOHERENT", t.text, re.IGNORECASE) for t in tokens
    )
    words = [t for t in tokens if t.kind != "pragma"]
    arrow = first_at_depth_zero(words, "=>")
    start = next((i + 1 for i, t in enumerate(words) if t.text == "instance"), 1)
    words = words[arrow + 1 :] if arrow is not None else words[start:]
    if not words or not is_upper(words[0]):
        # An unusual head: treat it as able to overlap.
        return "", [], True
    arguments, index = [], 1
    while index < len(words):
        token = words[index]
        if token.text in ("(", "["):
            end = closing(words, index)
            inner = words[index + 1 : end]
            if token.text == "[":
                arguments.append("[]")
            elif len(split_commas(inner)) > 1:
                arguments.append("(" + "," * (len(split_commas(inner)) - 1) + ")")
            elif first_at_depth_zero(inner, "->") is not None:
                arguments.append("->")
            elif not inner:
                arguments.append("()")
            else:
                arguments.append(inner[0].text if is_upper(inner[0]) else "")
            index = end
        elif is_upper(token):
            arguments.append(token.text)
        elif token.text != "'":
            arguments.append("")
        index += 1
    return base_name(words[0].text), arguments, flagged


class Module:
    """One parsed library module."""

    def __init__(self, text):
        tokens = tokenize(text)
        self.extensions, self.options = set(), []
        while tokens and tokens[0].kind == "pragma":
            self._file_pragma(tokens.pop(0).text)
        if len(tokens) < 3 or tokens[0].text != "module" or tokens[2].text != "(":
            if len(tokens) < 3 or tokens[2].kind != "pragma":
                raise SourceError("module has no explicit export list")
            raise SourceError("module-level pragmas are not supported")
        self.name = tokens[1].text
        end = closing(tokens, 2)
        self.exports = parse_entries(tokens[3:end])
        if tokens[end + 1].text != "where":
            raise SourceError("cannot parse the module header")
        self.imports = []
        self.types = {}  # type/class name -> kind
        self.members = {}  # constructor/field/method -> parent type
        self.children = {}  # type -> its constructors, fields and methods
        self.parts = {}  # name -> [token list]
        self.abstract = {}  # data name -> token list without its constructors
        self.instances = []  # (key tokens, rendered body types)
        self.module_parts = []  # rendered module-wide pragmas
        self.fixities = {}
        self.bindings = set()  # values bound here, with or without a signature
        self.standalone = []
        for chunk in chunks(tokens[end + 2 :]):
            self._declaration(chunk)

    def _file_pragma(self, text):
        match = re.match(r"\{-#\s*(\w+)\s+(.*?)\s*#-\}$", text)
        if match and match[1].upper() == "LANGUAGE":
            self.extensions.update(word.strip() for word in match[2].split(","))
        elif match and match[1].upper() in ("OPTIONS_GHC", "OPTIONS_HADDOCK"):
            if match[1].upper() == "OPTIONS_GHC":
                self.options.append(match[2])
        else:
            raise SourceError(f"unsupported pragma {text}")
        if self.extensions & FORBIDDEN_EXTENSIONS:
            raise SourceError("unsupported language extension")
        if any(FORBIDDEN_OPTIONS.search(option) for option in self.options):
            raise SourceError("unsupported compiler option")

    def _add(self, name, tokens):
        self.parts.setdefault(name, []).append(list(tokens))

    def _declaration(self, chunk):
        first = chunk[0]
        if first.column != 0:
            raise SourceError(f"line {first.line}: declarations must start in column zero")
        if any(t.text == ";" for t in chunk):
            raise SourceError(f"line {first.line}: semicolons are not supported")
        if any(t.kind == "pragma" and re.match(r"\{-#\s*(RULES|ANN)\b", t.text, re.IGNORECASE) for t in chunk):
            raise SourceError(f"line {first.line}: RULES and ANN are not supported")
        keyword = first.text if first.kind == "ident" else first.kind
        handler = {
            "import": lambda: self.imports.append(parse_import(chunk)),
            "pragma": lambda: self._pragma(chunk),
            "data": lambda: self._data(chunk),
            "newtype": lambda: self._data(chunk),
            "type": lambda: self._type(chunk),
            "class": lambda: self._class(chunk),
            "instance": lambda: self._instance(chunk),
            "deriving": lambda: self._deriving(chunk),
            "pattern": lambda: self._pattern(chunk),
            "infix": lambda: self._fixity(chunk),
            "infixl": lambda: self._fixity(chunk),
            "infixr": lambda: self._fixity(chunk),
            "foreign": lambda: self._foreign(chunk),
        }.get(keyword)
        if handler:
            handler()
            return
        names = signature_names(chunk)
        if names is not None:
            for name in names:
                self._add(name, chunk)
                if any(t.text == "_" for t in chunk):
                    raise SourceError(f"line {first.line}: partial type signature")
        elif keyword == "default" or first_at_depth_zero(chunk, "=", "|") is None:
            # A naked top-level expression is a Template Haskell splice.
            raise SourceError(f"line {first.line}: unsupported declaration")
        else:
            left = chunk[: first_at_depth_zero(chunk, "=", "|")]
            if first.kind == "ident" and not is_upper(first):
                self.bindings.add(binding_name(chunk))
            self.bindings.update(
                t.text for t in left if first.kind != "ident" or is_upper(first) or t.kind == "operator"
            )

    def _pragma(self, chunk):
        # An indented continuation would belong to a declaration.
        if len(chunk) != 1:
            raise SourceError(f"line {chunk[0].line}: pragma shares a declaration")
        match = re.match(r"\{-#\s*(\w+)", chunk[0].text)
        if not match:
            raise SourceError(f"line {chunk[0].line}: unsupported pragma")
        if match[1].upper() not in IGNORED_PRAGMAS:
            self.module_parts.append(chunk[0].text)

    def _data(self, chunk):
        rest = chunk[1:]
        if rest[0].text in ("instance", "family"):
            raise SourceError(f"line {chunk[0].line}: data families are not supported")
        cut = first_at_depth_zero(rest, "=", "where", "deriving")
        head = rest if cut is None else rest[:cut]
        name, parameters = declared_head(head)
        self.types[name] = "data"
        self._add(name, chunk)
        children = set()
        for index, token in enumerate(rest[len(head) :]):
            if is_upper(token):
                children.add(token.text)
            following = rest[len(head) + index + 1 :][:1]
            if token.kind == "ident" and not is_upper(token) and following and following[0].text in ("::", ","):
                children.add(token.text)
            if token.kind == "operator" and token.text[0] == ":" and token.text not in ("::", ":"):
                children.add(token.text)
        deriving = first_at_depth_zero(rest, "deriving")
        constructors = rest[len(head) : deriving]
        derived = {t.text for t in rest[deriving:]} if deriving is not None else set()
        # Over-approximates: types used in fields count as constructors too,
        # so restrict lookups to names that can be constructors.
        real = set()
        if constructors:
            expecting = True
            for _, token in depth_zero(constructors):
                if token.text in ("=", "|", "where"):
                    expecting = True
                elif expecting and is_upper(token):
                    real.add(token.text)
                    expecting = False
            if constructors[0].text == "where":
                real |= {
                    n for item in body_items(constructors[1:]) for n in signature_names(item) or []
                }
            # A constructor context (forall a. Show a => C) hides the real name.
            if any(t.text in ("forall", "=>") for t in constructors):
                real |= {t.text for t in constructors if is_upper(t)} - set(PRELUDE)
        fields = {c for c in children if not c[0].isupper()}
        self.children[name] = real | fields
        for child in real | fields:
            self.members.setdefault(child, name)
        exposing = parameters or derived & EXPOSING_DERIVATIONS
        self.abstract[name] = (
            list(chunk) if exposing else [chunk[0], *head, *(rest[deriving:] if deriving is not None else [])]
        )

    def _type(self, chunk):
        rest = chunk[1:]
        if rest[0].text in ("instance", "family", "data"):
            raise SourceError(f"line {chunk[0].line}: type families are not supported")
        if rest[0].text == "role":
            rest = rest[1:]
            name = rest[0].text
        else:
            name, _ = declared_head(rest)
            if first_at_depth_zero(rest, "::") is None or first_at_depth_zero(rest, "=") is not None:
                self.types[name] = "type"
        self._add(name, chunk)
        if name not in self.types or self.types[name] != "type":
            self.standalone.append((name, chunk))

    def _class(self, chunk):
        head, body = split_where(chunk[1:])
        pipe = first_at_depth_zero(head, "|")
        name, _ = declared_head(head if pipe is None else head[:pipe])
        self.types[name] = "class"
        shape, defaults, children = [chunk[0], *head], set(), set()
        for item in body_items(body):
            names = signature_names(item)
            if names is not None:
                shape += item
                children.update(names)
            elif item[0].kind == "pragma" and "MINIMAL" not in item[0].text.upper():
                continue
            elif item[0].kind == "pragma" or item[0].text.startswith("infix"):
                shape += item
            elif item[0].text in ("type", "data", "default"):
                shape += item
                children.update(t.text for t in item if is_upper(t))
            else:
                defaults.add(binding_name(item) or render(item))
        self._add(name, shape)
        # The presence of a default matters to instances; its body does not.
        self.parts[name].append([t for t in tokenize(" ".join(sorted(defaults)))])
        self.children[name] = children
        for child in children:
            self.members.setdefault(child, name)

    def _instance(self, chunk):
        head, body = split_where(chunk[1:])
        associated = [t for item in body_items(body) if item[0].text in ("type", "data", "newtype") for t in item]
        self.instances.append([chunk[0], *head, *associated])

    def _deriving(self, chunk):
        if any(t.text in EXPOSING_DERIVATIONS for t in chunk):
            raise SourceError(f"line {chunk[0].line}: standalone deriving of a structural class")
        self.instances.append(list(chunk))

    def _pattern(self, chunk):
        if len(chunk) < 2 or not is_upper(chunk[1]):
            raise SourceError(f"line {chunk[0].line}: unsupported pattern synonym")
        index = first_at_depth_zero(chunk, "::")
        names = split_commas(chunk[1:index]) if index else [[chunk[1]]]
        for part in names:
            self._add(part[0].text, chunk)
            self.members.setdefault(part[0].text, part[0].text)

    def _fixity(self, chunk):
        for token in chunk[1:]:
            if token.kind in ("operator", "ident"):
                self.fixities.setdefault(token.text, []).append(render(chunk))

    def _foreign(self, chunk):
        index = first_at_depth_zero(chunk, "::")
        if index is None:
            raise SourceError(f"line {chunk[0].line}: cannot parse foreign declaration")
        self._add(chunk[index - 1].text, chunk)


class Package:
    """All library modules of one package; read(path) returns text or None."""

    def __init__(self, cabal_text, directory, read):
        self.modules = {}
        self.exposed = set()
        self.items = {}
        reexports = []
        for library in cabal_file.libraries(cabal_file.parse(cabal_text)):
            for name in (*library.exposed, *library.other):
                if name in self.modules:
                    raise ApiError(f"{name} is listed by two libraries")
                found = []
                for source_dir in library.source_dirs:
                    parts = [p for p in (directory, source_dir) if p not in ("", ".")]
                    path = "/".join([*parts, name.replace(".", "/") + ".hs"])
                    text = read(path)
                    if text is not None:
                        found.append((path, text))
                if len(found) != 1:
                    raise ApiError(f"expected one source file for {name}, found {len(found)}")
                try:
                    module = Module(found[0][1])
                except (SourceError, IndexError) as error:
                    raise ApiError(f"{found[0][0]}: {error}") from error
                if module.name != name:
                    raise ApiError(f"{found[0][0]} declares {module.name}")
                self.modules[name] = module
            for name in library.exposed:
                self.exposed.add(name)
                self.items[f"{library.name} exposes {name}"] = ""
            for name in library.reexported:
                reexports.append((library.name, name))
        for library, name in reexports:
            if name not in self.modules:
                raise ApiError(f"reexported module {name} is not local")
            self.exposed.add(name)
            self.items[f"{library} exposes {name}"] = ""

    # Name resolution

    def provides(self, module, name, seen=()):
        """Origins of name as exported by a local module."""
        if (module, name) in seen:
            return set()
        seen = (*seen, (module, name))
        current, origins = self.modules[module], set()
        for entry in current.exports:
            if entry.namespace == "module":
                for item in current.imports:
                    if item.alias == entry.name:
                        origins |= self.through_import(item, name, seen)
                continue
            if base_name(entry.name) == name:
                origins |= self.resolve(module, entry.name, seen)
            elif entry.subs == ".." or (entry.subs and name in entry.subs):
                for origin in self.resolve(module, entry.name, seen):
                    owner = self.modules.get(origin[0])
                    if owner and name in owner.children.get(origin[1], ()):
                        origins.add((origin[0], name))
        return origins

    def through_import(self, item, name, seen=()):
        if item.entries is not None:
            listed, via_open_parent = False, False
            for entry in item.entries:
                if entry.name == name or (isinstance(entry.subs, tuple) and name in entry.subs):
                    listed = True
                elif entry.subs == "..":
                    via_open_parent = True
            if item.hiding:
                if listed:
                    return set()
            elif not listed and not via_open_parent:
                return set()
            elif not listed and item.module not in self.modules:
                # A constructor of an external T(..) import.
                return {("?" + item.module, name)}
            elif listed and item.module not in self.modules:
                return {(item.module, name)}
        if item.module in self.modules:
            return self.provides(item.module, name, seen)
        return {("?" + item.module, name)}

    def resolve(self, module, text, seen=()):
        """Possible origins of a possibly qualified name used in a module."""
        current, name = self.modules[module], base_name(text)
        prefix = text[: -len(name) - 1] if text != name else None
        if prefix is None or prefix == module:
            if name in current.types or name in current.members or name in current.parts or name in current.bindings:
                return {(module, name)}
        if prefix is None and name in PRELUDE and not any(i.module == "Prelude" for i in current.imports):
            explicit = [
                i for i in current.imports
                if i.entries is not None and not i.hiding and any(e.name == name for e in i.entries)
            ]
            if not explicit:
                return {("Prelude", name)}
        origins = set()
        for item in current.imports:
            if (prefix is None and not item.qualified) or prefix == item.alias:
                origins |= self.through_import(item, name, seen)
        exact = {o for o in origins if not o[0].startswith("?")}
        return exact or origins

    # Fingerprints

    def own_tokens(self, origin, full):
        module = self.modules[origin[0]]
        name = origin[1]
        parent = module.members.get(name)
        if name not in module.types and parent and parent != name:
            name, full = parent, True
        if not full and name in module.abstract:
            extra = [t for owner, chunk in module.standalone if owner == name for t in chunk]
            return name, [*module.abstract[name], *extra]
        return name, [t for part in module.parts.get(name, []) for t in part]

    def fingerprint(self, module, tokens):
        """Source text plus what every type name in it, transitively, means."""
        lines, pending, done = [render(tokens)], [], set()

        def visit(context, found):
            for token in found:
                if is_upper(token):
                    origins = self.resolve(context, token.text)
                    if not origins:
                        # Constructors and type variables of DataKinds, modules, strings.
                        lines.append(f"{context}: {token.text} unresolved")
                    for origin in sorted(origins):
                        lines.append(f"{context}: {token.text} = {origin[0]}.{origin[1]}")
                        if origin[0] in self.modules and origin not in done:
                            done.add(origin)
                            pending.append(origin)

        visit(module, tokens)
        while pending:
            origin = pending.pop()
            name, found = self.own_tokens(origin, False)
            lines.append(f"{origin[0]}.{name}: {render(found)}")
            visit(origin[0], found)
        return "\n".join(sorted(set(lines[1:]))) + "\n" + lines[0]

    def describe(self, module, entry):
        """Fingerprint of one export entry seen from a module."""
        origins = self.resolve(module, entry.name)
        if not origins:
            raise ApiError(f"{module}: cannot find exported {entry.text}")
        result = []
        for origin in sorted(origins):
            if origin[0] not in self.modules:
                result.append(f"{entry.text} from {origin[0]}")
                continue
            owner = self.modules[origin[0]]
            if not owner.parts.get(origin[1]) and origin[1] not in owner.members:
                raise ApiError(f"{module}: {entry.text} has no type signature")
            _, tokens = self.own_tokens(origin, entry.subs is not None)
            names = {origin[1], *owner.children.get(origin[1], ())}
            fixities = sorted(f for n in names for f in owner.fixities.get(n, ()))
            result.append(
                f"{entry.text} = {origin[0]}.{origin[1]} {fixities} {self.fingerprint(origin[0], tokens)}"
            )
        return "\n".join(result)

    def exports(self, module, seen=()):
        """[(name, fingerprint)] for every export of a local module."""
        if module in seen:
            raise ApiError(f"{module}: cyclic re-export")
        current, result = self.modules[module], []
        for entry in current.exports:
            if entry.namespace != "module":
                name = base_name(entry.name)
                kind = "pattern " if entry.namespace == "pattern" else ""
                result.append((kind + name, self.describe(module, entry)))
                continue
            imports = [i for i in current.imports if i.alias == entry.name]
            if entry.name == module or not imports:
                raise ApiError(f"{module}: unsupported re-export of {entry.name}")
            forms = sorted(f"{i.module} qualified={i.qualified}" for i in imports)
            result.append((f"module {entry.name}", "\n".join(forms)))
            for item in imports:
                # A qualified-only import re-exports nothing in Haskell unless the
                # names are also in scope unqualified; including it is stricter.
                if item.module not in self.modules:
                    result.append((f"module {entry.name} via {item.module}", item.text))
                elif item.entries is None or item.hiding:
                    hidden = {e.name for e in item.entries or ()}
                    if item.hiding:
                        result.append((f"module {entry.name} via {item.module}", item.text))
                    result += [
                        pair for pair in self.exports(item.module, (*seen, module))
                        if pair[0] not in hidden
                    ]
                else:
                    for listed in item.entries:
                        scoped = listed._replace(name=f"{item.alias}.{listed.name}")
                        result.append((listed.name, self.describe(module, scoped)))
        return result

    def overlapping_classes(self):
        """Classes whose instances may overlap, so that adding one is not safe."""
        shapes, result = {}, set()
        for module in self.modules.values():
            for tokens in module.instances:
                name, arguments, flagged = instance_shape(tokens)
                synonyms = {"String", "FilePath"} | {
                    t for m in self.modules.values() for t, kind in m.types.items() if kind == "type"
                }
                # Two instances with the same outer constructors, or a variable or
                # synonym as an argument, may overlap.
                if flagged or not arguments or any(not a or base_name(a) in synonyms for a in arguments):
                    result.add(name)
                shape = tuple(arguments)
                if shape in shapes.setdefault(name, set()):
                    result.add(name)
                shapes[name].add(shape)
        return result

    def surface(self):
        items = {key: {value} for key, value in self.items.items()}

        def add(key, value):
            items.setdefault(key, set()).add(value)

        for name in sorted(self.exposed):
            for export, fingerprint in self.exports(name):
                add(f"{name}: {export}", fingerprint)
        overlapping = self.overlapping_classes()
        for name, module in self.modules.items():
            # These bring unlisted names or only instances into scope.
            opened = sorted(
                i.text for i in module.imports
                if i.module not in self.modules
                and ((not i.qualified and (i.entries is None or i.hiding)) or (i.entries == [] and not i.hiding))
            )
            add(f"{name}: open imports", "\n".join(opened))
            extensions = sorted(module.extensions - NEUTRAL_EXTENSIONS)
            add(f"{name}: extensions", f"{extensions} {sorted(module.options)}")
            for text in module.module_parts:
                add(f"{name}: {text}", "")
            for tokens in module.instances:
                arrow = first_at_depth_zero(tokens, "=>")
                head = tokens[1:] if arrow is None else tokens[arrow + 1 :]
                origins = [o for t in head if is_upper(t) for o in self.resolve(name, t.text)]
                orphan = not any(o[0] == name for o in origins)
                overlap = instance_shape(tokens)[0] in overlapping
                # What standalone deriving exposes depends on hidden constructors.
                derived = "derived " if tokens[0].text == "deriving" else ""
                key = f"{derived}{'overlapping ' if overlap else ''}{'orphan ' if orphan else ''}{render(tokens)}"
                add(key, self.fingerprint(name, tokens))
        return {key: "\n".join(sorted(values)) for key, values in items.items()}


def surface(cabal_text, directory, read):
    try:
        return Package(cabal_text, directory, read).surface()
    except (SourceError, cabal_file.CabalError) as error:
        raise ApiError(str(error)) from error


def compare(base, head):
    """Return (status, changes); status is unchanged, compatible or breaking."""
    changes = []
    for key in sorted(base.keys() - head.keys()):
        changes.append({"kind": "breaking", "change": f"removed {key}"})
    for key in sorted(base.keys() & head.keys()):
        if base[key] != head[key]:
            changes.append({"kind": "breaking", "change": f"changed {key}"})
    for key in sorted(head.keys() - base.keys()):
        kind = "breaking" if key.startswith(("orphan ", "overlapping ", "derived ")) else "compatible"
        changes.append({"kind": kind, "change": f"added {key}"})
    kinds = {change["kind"] for change in changes}
    if "breaking" in kinds:
        return "breaking", changes
    return ("compatible" if kinds else "unchanged"), changes
