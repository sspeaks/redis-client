# Share command descriptors across interpreters

Typed command frames and their routing hints are defined once as `CommandDescriptor` values, used by the sequential, standalone and cluster interpreters instead of three hand-copied implementations.

A command that requires keys but receives an empty key list is routed through generated metadata, so arity validation rejects it instead of it being treated as keyless.
