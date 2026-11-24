# Share command descriptors across interpreters

Typed command frames and their routing hints are defined once as `CommandDescriptor` values, used by the sequential, standalone and cluster interpreters instead of three hand-copied implementations.

UNLINK, PFCOUNT, SDIFF, SINTER and SUNION with an empty key list are routed through generated metadata, so arity validation rejects them instead of them being treated as keyless. Other multi-key commands, such as MGET, MSET, DEL and EXISTS, still treat an empty key list as keyless.
