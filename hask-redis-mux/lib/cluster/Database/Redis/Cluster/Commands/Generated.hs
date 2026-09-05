{-# LANGUAGE OverloadedStrings #-}

module Database.Redis.Cluster.Commands.Generated
  ( redis72SourceSha
  , generatedSupportedFormsCount
  , generatedCommandSpecs
  ) where

import           Database.Redis.Cluster.Commands.Spec

redis72SourceSha :: String
redis72SourceSha = "ae6a2aa95cd094b032e7a69b8b59f64dd1ed085f"

generatedSupportedFormsCount :: Int
generatedSupportedFormsCount = 392

-- Generated from vendor/redis-7.2.6/src/commands/*.json
-- by scripts/generate_cluster_routing.py

generatedCommandSpecs :: [GeneratedCommandSpec]
generatedCommandSpecs =
  [
  GeneratedCommandSpec
    { gcsTokens = ["ACL"]
    , gcsArity = -2
    , gcsFlags = ["SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "CAT"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "category"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "DELUSER"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "username"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "DRYRUN"]
    , gcsArity = -4
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "username"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "command"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "GENPASS"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "bits"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "GETUSER"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "username"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "LIST"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "LOAD"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "LOG"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "operation"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "integer"
                      , gaName = "count"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "reset"
                      , gaToken = Just "RESET"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "SAVE"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "SETUSER"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "username"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "rule"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "USERS"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["ACL", "WHOAMI"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["APPEND"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ASKING"]
    , gcsArity = 1
    , gcsFlags = ["FAST"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["AUTH"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "NO_AUTH", "SENTINEL", "ALLOW_BUSY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "username"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "password"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BGREWRITEAOF"]
    , gcsArity = 1
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["BGSAVE"]
    , gcsArity = -1
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "schedule"
            , gaToken = Just "SCHEDULE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BITCOUNT"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "range"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "start"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "end"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "oneof"
                    , gaName = "unit"
                    , gaToken = Nothing
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives =
                        [
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "byte"
                              , gaToken = Just "BYTE"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ],
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "bit"
                              , gaToken = Just "BIT"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                        ]
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BITFIELD"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "operation"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "get-block"
                      , gaToken = Just "GET"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "encoding"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "integer"
                              , gaName = "offset"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "write"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "oneof"
                              , gaName = "overflow-block"
                              , gaToken = Just "OVERFLOW"
                              , gaOptional = True
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives =
                                  [
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "wrap"
                                        , gaToken = Just "WRAP"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "sat"
                                        , gaToken = Just "SAT"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "fail"
                                        , gaToken = Just "FAIL"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ]
                                  ]
                              },
                            GeneratedArgument
                              { gaType = "oneof"
                              , gaName = "write-operation"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives =
                                  [
                                    [
                                      GeneratedArgument
                                        { gaType = "block"
                                        , gaName = "set-block"
                                        , gaToken = Just "SET"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren =
                                            [
                                              GeneratedArgument
                                                { gaType = "string"
                                                , gaName = "encoding"
                                                , gaToken = Nothing
                                                , gaOptional = False
                                                , gaMultiple = False
                                                , gaKeySpecIndex = Nothing
                                                , gaChildren = []
                                                , gaAlternatives = []
                                                },
                                              GeneratedArgument
                                                { gaType = "integer"
                                                , gaName = "offset"
                                                , gaToken = Nothing
                                                , gaOptional = False
                                                , gaMultiple = False
                                                , gaKeySpecIndex = Nothing
                                                , gaChildren = []
                                                , gaAlternatives = []
                                                },
                                              GeneratedArgument
                                                { gaType = "integer"
                                                , gaName = "value"
                                                , gaToken = Nothing
                                                , gaOptional = False
                                                , gaMultiple = False
                                                , gaKeySpecIndex = Nothing
                                                , gaChildren = []
                                                , gaAlternatives = []
                                                }
                                            ]
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "block"
                                        , gaName = "incrby-block"
                                        , gaToken = Just "INCRBY"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren =
                                            [
                                              GeneratedArgument
                                                { gaType = "string"
                                                , gaName = "encoding"
                                                , gaToken = Nothing
                                                , gaOptional = False
                                                , gaMultiple = False
                                                , gaKeySpecIndex = Nothing
                                                , gaChildren = []
                                                , gaAlternatives = []
                                                },
                                              GeneratedArgument
                                                { gaType = "integer"
                                                , gaName = "offset"
                                                , gaToken = Nothing
                                                , gaOptional = False
                                                , gaMultiple = False
                                                , gaKeySpecIndex = Nothing
                                                , gaChildren = []
                                                , gaAlternatives = []
                                                },
                                              GeneratedArgument
                                                { gaType = "integer"
                                                , gaName = "increment"
                                                , gaToken = Nothing
                                                , gaOptional = False
                                                , gaMultiple = False
                                                , gaKeySpecIndex = Nothing
                                                , gaChildren = []
                                                , gaAlternatives = []
                                                }
                                            ]
                                        , gaAlternatives = []
                                        }
                                    ]
                                  ]
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BITFIELD_RO"]
    , gcsArity = -2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "get-block"
            , gaToken = Just "GET"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "encoding"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BITOP"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "operation"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "and"
                      , gaToken = Just "AND"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "or"
                      , gaToken = Just "OR"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xor"
                      , gaToken = Just "XOR"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "not"
                      , gaToken = Just "NOT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destkey"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BITPOS"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "bit"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "range"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "start"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "block"
                    , gaName = "end-unit-block"
                    , gaToken = Nothing
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren =
                        [
                          GeneratedArgument
                            { gaType = "integer"
                            , gaName = "end"
                            , gaToken = Nothing
                            , gaOptional = False
                            , gaMultiple = False
                            , gaKeySpecIndex = Nothing
                            , gaChildren = []
                            , gaAlternatives = []
                            },
                          GeneratedArgument
                            { gaType = "oneof"
                            , gaName = "unit"
                            , gaToken = Nothing
                            , gaOptional = True
                            , gaMultiple = False
                            , gaKeySpecIndex = Nothing
                            , gaChildren = []
                            , gaAlternatives =
                                [
                                  [
                                    GeneratedArgument
                                      { gaType = "pure-token"
                                      , gaName = "byte"
                                      , gaToken = Just "BYTE"
                                      , gaOptional = False
                                      , gaMultiple = False
                                      , gaKeySpecIndex = Nothing
                                      , gaChildren = []
                                      , gaAlternatives = []
                                      }
                                  ],
                                  [
                                    GeneratedArgument
                                      { gaType = "pure-token"
                                      , gaName = "bit"
                                      , gaToken = Just "BIT"
                                      , gaOptional = False
                                      , gaMultiple = False
                                      , gaKeySpecIndex = Nothing
                                      , gaChildren = []
                                      , gaAlternatives = []
                                      }
                                  ]
                                ]
                            }
                        ]
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BLMOVE"]
    , gcsArity = 6
    , gcsFlags = ["WRITE", "DENYOOM", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "wherefrom"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "left"
                      , gaToken = Just "LEFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "right"
                      , gaToken = Just "RIGHT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "whereto"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "left"
                      , gaToken = Just "LEFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "right"
                      , gaToken = Just "RIGHT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BLMPOP"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "where"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "left"
                      , gaToken = Just "LEFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "right"
                      , gaToken = Just "RIGHT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BLPOP"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BRPOP"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BRPOPLPUSH"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BZMPOP"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "where"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "min"
                      , gaToken = Just "MIN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "max"
                      , gaToken = Just "MAX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BZPOPMAX"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["BZPOPMIN"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT"]
    , gcsArity = -2
    , gcsFlags = ["SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "CACHING"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "mode"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "yes"
                      , gaToken = Just "YES"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "no"
                      , gaToken = Just "NO"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "GETNAME"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "GETREDIR"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "ID"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "INFO"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "KILL"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "filter"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "old-format"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "oneof"
                      , gaName = "new-format"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = True
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives =
                          [
                            [
                              GeneratedArgument
                                { gaType = "integer"
                                , gaName = "client-id"
                                , gaToken = Just "ID"
                                , gaOptional = True
                                , gaMultiple = False
                                , gaKeySpecIndex = Nothing
                                , gaChildren = []
                                , gaAlternatives = []
                                }
                            ],
                            [
                              GeneratedArgument
                                { gaType = "oneof"
                                , gaName = "client-type"
                                , gaToken = Just "TYPE"
                                , gaOptional = True
                                , gaMultiple = False
                                , gaKeySpecIndex = Nothing
                                , gaChildren = []
                                , gaAlternatives =
                                    [
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "normal"
                                          , gaToken = Just "normal"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ],
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "master"
                                          , gaToken = Just "master"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ],
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "slave"
                                          , gaToken = Just "slave"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ],
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "replica"
                                          , gaToken = Just "replica"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ],
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "pubsub"
                                          , gaToken = Just "pubsub"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ]
                                    ]
                                }
                            ],
                            [
                              GeneratedArgument
                                { gaType = "string"
                                , gaName = "username"
                                , gaToken = Just "USER"
                                , gaOptional = True
                                , gaMultiple = False
                                , gaKeySpecIndex = Nothing
                                , gaChildren = []
                                , gaAlternatives = []
                                }
                            ],
                            [
                              GeneratedArgument
                                { gaType = "string"
                                , gaName = "addr"
                                , gaToken = Just "ADDR"
                                , gaOptional = True
                                , gaMultiple = False
                                , gaKeySpecIndex = Nothing
                                , gaChildren = []
                                , gaAlternatives = []
                                }
                            ],
                            [
                              GeneratedArgument
                                { gaType = "string"
                                , gaName = "laddr"
                                , gaToken = Just "LADDR"
                                , gaOptional = True
                                , gaMultiple = False
                                , gaKeySpecIndex = Nothing
                                , gaChildren = []
                                , gaAlternatives = []
                                }
                            ],
                            [
                              GeneratedArgument
                                { gaType = "oneof"
                                , gaName = "skipme"
                                , gaToken = Just "SKIPME"
                                , gaOptional = True
                                , gaMultiple = False
                                , gaKeySpecIndex = Nothing
                                , gaChildren = []
                                , gaAlternatives =
                                    [
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "yes"
                                          , gaToken = Just "YES"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ],
                                      [
                                        GeneratedArgument
                                          { gaType = "pure-token"
                                          , gaName = "no"
                                          , gaToken = Just "NO"
                                          , gaOptional = False
                                          , gaMultiple = False
                                          , gaKeySpecIndex = Nothing
                                          , gaChildren = []
                                          , gaAlternatives = []
                                          }
                                      ]
                                    ]
                                }
                            ]
                          ]
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "LIST"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "client-type"
            , gaToken = Just "TYPE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "normal"
                      , gaToken = Just "normal"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "master"
                      , gaToken = Just "master"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "replica"
                      , gaToken = Just "replica"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "pubsub"
                      , gaToken = Just "pubsub"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "client-id"
            , gaToken = Just "ID"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "NO-EVICT"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "enabled"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "on"
                      , gaToken = Just "ON"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "off"
                      , gaToken = Just "OFF"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "NO-TOUCH"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "enabled"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "on"
                      , gaToken = Just "ON"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "off"
                      , gaToken = Just "OFF"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "PAUSE"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "mode"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "write"
                      , gaToken = Just "WRITE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "all"
                      , gaToken = Just "ALL"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "REPLY"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "action"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "on"
                      , gaToken = Just "ON"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "off"
                      , gaToken = Just "OFF"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "skip"
                      , gaToken = Just "SKIP"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "SETINFO"]
    , gcsArity = 4
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "attr"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "libname"
                      , gaToken = Just "lib-name"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "libver"
                      , gaToken = Just "lib-ver"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "SETNAME"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "connection-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "TRACKING"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "status"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "on"
                      , gaToken = Just "ON"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "off"
                      , gaToken = Just "OFF"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "client-id"
            , gaToken = Just "REDIRECT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "prefix"
            , gaToken = Just "PREFIX"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "BCAST"
            , gaToken = Just "BCAST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "OPTIN"
            , gaToken = Just "OPTIN"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "OPTOUT"
            , gaToken = Just "OPTOUT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "NOLOOP"
            , gaToken = Just "NOLOOP"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "TRACKINGINFO"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "UNBLOCK"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "client-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "unblock-type"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "timeout"
                      , gaToken = Just "TIMEOUT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "error"
                      , gaToken = Just "ERROR"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLIENT", "UNPAUSE"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "ADDSLOTS"]
    , gcsArity = -3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "slot"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "ADDSLOTSRANGE"]
    , gcsArity = -4
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "range"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "start-slot"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "end-slot"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "BUMPEPOCH"]
    , gcsArity = 2
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "COUNT-FAILURE-REPORTS"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "node-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "COUNTKEYSINSLOT"]
    , gcsArity = 3
    , gcsFlags = ["STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "slot"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "DELSLOTS"]
    , gcsArity = -3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "slot"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "DELSLOTSRANGE"]
    , gcsArity = -4
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "range"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "start-slot"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "end-slot"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "FAILOVER"]
    , gcsArity = -2
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "options"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "force"
                      , gaToken = Just "FORCE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "takeover"
                      , gaToken = Just "TAKEOVER"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "FLUSHSLOTS"]
    , gcsArity = 2
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "FORGET"]
    , gcsArity = 3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "node-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "GETKEYSINSLOT"]
    , gcsArity = 4
    , gcsFlags = ["STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "slot"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "INFO"]
    , gcsArity = 2
    , gcsFlags = ["STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "KEYSLOT"]
    , gcsArity = 3
    , gcsFlags = ["STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "LINKS"]
    , gcsArity = 2
    , gcsFlags = ["STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "MEET"]
    , gcsArity = -4
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "ip"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "port"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "cluster-bus-port"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "MYID"]
    , gcsArity = 2
    , gcsFlags = ["STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "MYSHARDID"]
    , gcsArity = 2
    , gcsFlags = ["STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "NODES"]
    , gcsArity = 2
    , gcsFlags = ["STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "REPLICAS"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "node-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "REPLICATE"]
    , gcsArity = 3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "node-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "RESET"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "STALE", "NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "reset-type"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "hard"
                      , gaToken = Just "HARD"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "soft"
                      , gaToken = Just "SOFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "SAVECONFIG"]
    , gcsArity = 2
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "SET-CONFIG-EPOCH"]
    , gcsArity = 3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "config-epoch"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "SETSLOT"]
    , gcsArity = -4
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "slot"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "subcommand"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "importing"
                      , gaToken = Just "IMPORTING"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "migrating"
                      , gaToken = Just "MIGRATING"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "node"
                      , gaToken = Just "NODE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "stable"
                      , gaToken = Just "STABLE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "SHARDS"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "SLAVES"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "node-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CLUSTER", "SLOTS"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND"]
    , gcsArity = -1
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "COUNT"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "DOCS"]
    , gcsArity = -2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "command-name"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "GETKEYS"]
    , gcsArity = -3
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "command"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "GETKEYSANDFLAGS"]
    , gcsArity = -3
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "command"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "INFO"]
    , gcsArity = -2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "command-name"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["COMMAND", "LIST"]
    , gcsArity = -2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "filterby"
            , gaToken = Just "FILTERBY"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "module-name"
                      , gaToken = Just "MODULE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "category"
                      , gaToken = Just "ACLCAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pattern"
                      , gaName = "pattern"
                      , gaToken = Just "PATTERN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CONFIG"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CONFIG", "GET"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "parameter"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["CONFIG", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CONFIG", "RESETSTAT"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CONFIG", "REWRITE"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["CONFIG", "SET"]
    , gcsArity = -4
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "parameter"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["COPY"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "destination-db"
            , gaToken = Just "DB"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "replace"
            , gaToken = Just "REPLACE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["DBSIZE"]
    , gcsArity = 1
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["DEBUG"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "PROTECTED"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["DECR"]
    , gcsArity = 2
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["DECRBY"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "decrement"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["DEL"]
    , gcsArity = -2
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["DISCARD"]
    , gcsArity = 1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["DUMP"]
    , gcsArity = 2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ECHO"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "message"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EVAL"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "SKIP_MONITOR", "MAY_REPLICATE", "NO_MANDATORY_KEYS", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "script"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EVALSHA"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "SKIP_MONITOR", "MAY_REPLICATE", "NO_MANDATORY_KEYS", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "sha1"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EVALSHA_RO"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "SKIP_MONITOR", "NO_MANDATORY_KEYS", "STALE", "READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "sha1"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EVAL_RO"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "SKIP_MONITOR", "NO_MANDATORY_KEYS", "STALE", "READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "script"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EXEC"]
    , gcsArity = 1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "SKIP_SLOWLOG"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["EXISTS"]
    , gcsArity = -2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EXPIRE"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "seconds"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "gt"
                      , gaToken = Just "GT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "lt"
                      , gaToken = Just "LT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EXPIREAT"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "unix-time"
            , gaName = "unix-time-seconds"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "gt"
                      , gaToken = Just "GT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "lt"
                      , gaToken = Just "LT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["EXPIRETIME"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FAILOVER"]
    , gcsArity = -1
    , gcsFlags = ["ADMIN", "NOSCRIPT", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "target"
            , gaToken = Just "TO"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "host"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "port"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "force"
                    , gaToken = Just "FORCE"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "abort"
            , gaToken = Just "ABORT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "milliseconds"
            , gaToken = Just "TIMEOUT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FCALL"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "SKIP_MONITOR", "MAY_REPLICATE", "NO_MANDATORY_KEYS", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "function"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FCALL_RO"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "SKIP_MONITOR", "NO_MANDATORY_KEYS", "STALE", "READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "function"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FLUSHALL"]
    , gcsArity = -1
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "flush-type"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "async"
                      , gaToken = Just "ASYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sync"
                      , gaToken = Just "SYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FLUSHDB"]
    , gcsArity = -1
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "flush-type"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "async"
                      , gaToken = Just "ASYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sync"
                      , gaToken = Just "SYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "DELETE"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT", "WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "library-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "DUMP"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "FLUSH"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT", "WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "flush-type"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "async"
                      , gaToken = Just "ASYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sync"
                      , gaToken = Just "SYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "KILL"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "LIST"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "library-name-pattern"
            , gaToken = Just "LIBRARYNAME"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withcode"
            , gaToken = Just "WITHCODE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "LOAD"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "replace"
            , gaToken = Just "REPLACE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "function-code"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "RESTORE"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT", "WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "serialized-value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "policy"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "flush"
                      , gaToken = Just "FLUSH"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "append"
                      , gaToken = Just "APPEND"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "replace"
                      , gaToken = Just "REPLACE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["FUNCTION", "STATS"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEOADD"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "change"
            , gaToken = Just "CH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "double"
                    , gaName = "longitude"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "double"
                    , gaName = "latitude"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "member"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEODIST"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member1"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member2"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "unit"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "m"
                      , gaToken = Just "m"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "km"
                      , gaToken = Just "km"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "ft"
                      , gaToken = Just "ft"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "mi"
                      , gaToken = Just "mi"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEOHASH"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEOPOS"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEORADIUS"]
    , gcsArity = -6
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "longitude"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "latitude"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "radius"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "unit"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "m"
                      , gaToken = Just "m"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "km"
                      , gaToken = Just "km"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "ft"
                      , gaToken = Just "ft"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "mi"
                      , gaToken = Just "mi"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withcoord"
            , gaToken = Just "WITHCOORD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withdist"
            , gaToken = Just "WITHDIST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withhash"
            , gaToken = Just "WITHHASH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "count-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "any"
                    , gaToken = Just "ANY"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "store"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "key"
                      , gaName = "storekey"
                      , gaToken = Just "STORE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Just 1
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "key"
                      , gaName = "storedistkey"
                      , gaToken = Just "STOREDIST"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Just 2
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEORADIUSBYMEMBER"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "radius"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "unit"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "m"
                      , gaToken = Just "m"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "km"
                      , gaToken = Just "km"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "ft"
                      , gaToken = Just "ft"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "mi"
                      , gaToken = Just "mi"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withcoord"
            , gaToken = Just "WITHCOORD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withdist"
            , gaToken = Just "WITHDIST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withhash"
            , gaToken = Just "WITHHASH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "count-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "any"
                    , gaToken = Just "ANY"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "store"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "key"
                      , gaName = "storekey"
                      , gaToken = Just "STORE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Just 1
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "key"
                      , gaName = "storedistkey"
                      , gaToken = Just "STOREDIST"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Just 2
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEORADIUSBYMEMBER_RO"]
    , gcsArity = -5
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "radius"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "unit"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "m"
                      , gaToken = Just "m"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "km"
                      , gaToken = Just "km"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "ft"
                      , gaToken = Just "ft"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "mi"
                      , gaToken = Just "mi"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withcoord"
            , gaToken = Just "WITHCOORD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withdist"
            , gaToken = Just "WITHDIST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withhash"
            , gaToken = Just "WITHHASH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "count-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "any"
                    , gaToken = Just "ANY"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEORADIUS_RO"]
    , gcsArity = -6
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "longitude"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "latitude"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "radius"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "unit"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "m"
                      , gaToken = Just "m"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "km"
                      , gaToken = Just "km"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "ft"
                      , gaToken = Just "ft"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "mi"
                      , gaToken = Just "mi"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withcoord"
            , gaToken = Just "WITHCOORD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withdist"
            , gaToken = Just "WITHDIST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withhash"
            , gaToken = Just "WITHHASH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "count-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "any"
                    , gaToken = Just "ANY"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEOSEARCH"]
    , gcsArity = -7
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "from"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "member"
                      , gaToken = Just "FROMMEMBER"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "fromlonlat"
                      , gaToken = Just "FROMLONLAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "longitude"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "latitude"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "by"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "circle"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "radius"
                              , gaToken = Just "BYRADIUS"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "oneof"
                              , gaName = "unit"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives =
                                  [
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "m"
                                        , gaToken = Just "m"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "km"
                                        , gaToken = Just "km"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "ft"
                                        , gaToken = Just "ft"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "mi"
                                        , gaToken = Just "mi"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ]
                                  ]
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "box"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "width"
                              , gaToken = Just "BYBOX"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "height"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "oneof"
                              , gaName = "unit"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives =
                                  [
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "m"
                                        , gaToken = Just "m"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "km"
                                        , gaToken = Just "km"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "ft"
                                        , gaToken = Just "ft"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "mi"
                                        , gaToken = Just "mi"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ]
                                  ]
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "count-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "any"
                    , gaToken = Just "ANY"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withcoord"
            , gaToken = Just "WITHCOORD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withdist"
            , gaToken = Just "WITHDIST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withhash"
            , gaToken = Just "WITHHASH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GEOSEARCHSTORE"]
    , gcsArity = -8
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "from"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "member"
                      , gaToken = Just "FROMMEMBER"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "fromlonlat"
                      , gaToken = Just "FROMLONLAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "longitude"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "latitude"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "by"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "circle"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "radius"
                              , gaToken = Just "BYRADIUS"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "oneof"
                              , gaName = "unit"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives =
                                  [
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "m"
                                        , gaToken = Just "m"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "km"
                                        , gaToken = Just "km"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "ft"
                                        , gaToken = Just "ft"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "mi"
                                        , gaToken = Just "mi"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ]
                                  ]
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "box"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "width"
                              , gaToken = Just "BYBOX"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "double"
                              , gaName = "height"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "oneof"
                              , gaName = "unit"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives =
                                  [
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "m"
                                        , gaToken = Just "m"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "km"
                                        , gaToken = Just "km"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "ft"
                                        , gaToken = Just "ft"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ],
                                    [
                                      GeneratedArgument
                                        { gaType = "pure-token"
                                        , gaName = "mi"
                                        , gaToken = Just "mi"
                                        , gaOptional = False
                                        , gaMultiple = False
                                        , gaKeySpecIndex = Nothing
                                        , gaChildren = []
                                        , gaAlternatives = []
                                        }
                                    ]
                                  ]
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "count-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "any"
                    , gaToken = Just "ANY"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "storedist"
            , gaToken = Just "STOREDIST"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GET"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GETBIT"]
    , gcsArity = 3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "offset"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GETDEL"]
    , gcsArity = 2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GETEX"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "expiration"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "integer"
                      , gaName = "seconds"
                      , gaToken = Just "EX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "integer"
                      , gaName = "milliseconds"
                      , gaToken = Just "PX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "unix-time"
                      , gaName = "unix-time-seconds"
                      , gaToken = Just "EXAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "unix-time"
                      , gaName = "unix-time-milliseconds"
                      , gaToken = Just "PXAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "persist"
                      , gaToken = Just "PERSIST"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GETRANGE"]
    , gcsArity = 4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "end"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["GETSET"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HDEL"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HELLO"]
    , gcsArity = -1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "NO_AUTH", "SENTINEL", "ALLOW_BUSY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "arguments"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "protover"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "block"
                    , gaName = "auth"
                    , gaToken = Just "AUTH"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren =
                        [
                          GeneratedArgument
                            { gaType = "string"
                            , gaName = "username"
                            , gaToken = Nothing
                            , gaOptional = False
                            , gaMultiple = False
                            , gaKeySpecIndex = Nothing
                            , gaChildren = []
                            , gaAlternatives = []
                            },
                          GeneratedArgument
                            { gaType = "string"
                            , gaName = "password"
                            , gaToken = Nothing
                            , gaOptional = False
                            , gaMultiple = False
                            , gaKeySpecIndex = Nothing
                            , gaChildren = []
                            , gaAlternatives = []
                            }
                        ]
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "clientname"
                    , gaToken = Just "SETNAME"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HEXISTS"]
    , gcsArity = 3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HGET"]
    , gcsArity = 3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HGETALL"]
    , gcsArity = 2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HINCRBY"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "increment"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HINCRBYFLOAT"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "increment"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HKEYS"]
    , gcsArity = 2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HLEN"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HMGET"]
    , gcsArity = -3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HMSET"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "field"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HRANDFIELD"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "options"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "withvalues"
                    , gaToken = Just "WITHVALUES"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HSCAN"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "cursor"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Just "MATCH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HSET"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "field"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HSETNX"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HSTRLEN"]
    , gcsArity = 3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "field"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["HVALS"]
    , gcsArity = 2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["INCR"]
    , gcsArity = 2
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["INCRBY"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "increment"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["INCRBYFLOAT"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "increment"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["INFO"]
    , gcsArity = -1
    , gcsFlags = ["LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "section"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["KEYS"]
    , gcsArity = 2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LASTSAVE"]
    , gcsArity = 1
    , gcsFlags = ["LOADING", "STALE", "FAST"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "DOCTOR"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "GRAPH"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "event"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "HISTOGRAM"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "COMMAND"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "HISTORY"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "event"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "LATEST"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["LATENCY", "RESET"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "event"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LCS"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key1"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key2"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "len"
            , gaToken = Just "LEN"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "idx"
            , gaToken = Just "IDX"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "min-match-len"
            , gaToken = Just "MINMATCHLEN"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withmatchlen"
            , gaToken = Just "WITHMATCHLEN"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LINDEX"]
    , gcsArity = 3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "index"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LINSERT"]
    , gcsArity = 5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "where"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "before"
                      , gaToken = Just "BEFORE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "after"
                      , gaToken = Just "AFTER"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "pivot"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LLEN"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LMOVE"]
    , gcsArity = 5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "wherefrom"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "left"
                      , gaToken = Just "LEFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "right"
                      , gaToken = Just "RIGHT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "whereto"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "left"
                      , gaToken = Just "LEFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "right"
                      , gaToken = Just "RIGHT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LMPOP"]
    , gcsArity = -4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "where"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "left"
                      , gaToken = Just "LEFT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "right"
                      , gaToken = Just "RIGHT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LOLWUT"]
    , gcsArity = -1
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "version"
            , gaToken = Just "VERSION"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LPOP"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LPOS"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "rank"
            , gaToken = Just "RANK"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "num-matches"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "len"
            , gaToken = Just "MAXLEN"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LPUSH"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LPUSHX"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LRANGE"]
    , gcsArity = 4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "stop"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LREM"]
    , gcsArity = 4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LSET"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "index"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["LTRIM"]
    , gcsArity = 4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "stop"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY", "DOCTOR"]
    , gcsArity = 2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY", "MALLOC-STATS"]
    , gcsArity = 2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY", "PURGE"]
    , gcsArity = 2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY", "STATS"]
    , gcsArity = 2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MEMORY", "USAGE"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "SAMPLES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MGET"]
    , gcsArity = -2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MIGRATE"]
    , gcsArity = -6
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "host"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "port"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "key-selector"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "key"
                      , gaName = "key"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Just 0
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "empty-string"
                      , gaToken = Just "\"\""
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "destination-db"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "copy"
            , gaToken = Just "COPY"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "replace"
            , gaToken = Just "REPLACE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "authentication"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "auth"
                      , gaToken = Just "AUTH"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "auth2"
                      , gaToken = Just "AUTH2"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "username"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "password"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "keys"
            , gaToken = Just "KEYS"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MODULE"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MODULE", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MODULE", "LIST"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "NOSCRIPT"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MODULE", "LOAD"]
    , gcsArity = -3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT", "PROTECTED"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "path"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "arg"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MODULE", "LOADEX"]
    , gcsArity = -3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT", "PROTECTED"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "path"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "configs"
            , gaToken = Just "CONFIG"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "name"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "args"
            , gaToken = Just "ARGS"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MODULE", "UNLOAD"]
    , gcsArity = 3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT", "PROTECTED"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MONITOR"]
    , gcsArity = 1
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["MOVE"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "db"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MSET"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "key"
                    , gaName = "key"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Just 0
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MSETNX"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "key"
                    , gaName = "key"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Just 0
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["MULTI"]
    , gcsArity = 1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["OBJECT"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["OBJECT", "ENCODING"]
    , gcsArity = 3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["OBJECT", "FREQ"]
    , gcsArity = 3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["OBJECT", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["OBJECT", "IDLETIME"]
    , gcsArity = 3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["OBJECT", "REFCOUNT"]
    , gcsArity = 3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PERSIST"]
    , gcsArity = 2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PEXPIRE"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "milliseconds"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "gt"
                      , gaToken = Just "GT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "lt"
                      , gaToken = Just "LT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PEXPIREAT"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "unix-time"
            , gaName = "unix-time-milliseconds"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "gt"
                      , gaToken = Just "GT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "lt"
                      , gaToken = Just "LT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PEXPIRETIME"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PFADD"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PFCOUNT"]
    , gcsArity = -2
    , gcsFlags = ["READONLY", "MAY_REPLICATE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PFDEBUG"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "ADMIN"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "subcommand"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PFMERGE"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destkey"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "sourcekey"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PFSELFTEST"]
    , gcsArity = 1
    , gcsFlags = ["ADMIN"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["PING"]
    , gcsArity = -1
    , gcsFlags = ["FAST", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "message"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PSETEX"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "milliseconds"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PSUBSCRIBE"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PSYNC"]
    , gcsArity = -3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NO_MULTI", "NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "replicationid"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "offset"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PTTL"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBLISH"]
    , gcsArity = 3
    , gcsFlags = ["PUBSUB", "LOADING", "STALE", "FAST", "MAY_REPLICATE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "channel"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "message"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB", "CHANNELS"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB", "NUMPAT"]
    , gcsArity = 2
    , gcsFlags = ["PUBSUB", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB", "NUMSUB"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "channel"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB", "SHARDCHANNELS"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUBSUB", "SHARDNUMSUB"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "shardchannel"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["PUNSUBSCRIBE"]
    , gcsArity = -1
    , gcsFlags = ["PUBSUB", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["QUIT"]
    , gcsArity = -1
    , gcsFlags = ["ALLOW_BUSY", "NOSCRIPT", "LOADING", "STALE", "FAST", "NO_AUTH"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["RANDOMKEY"]
    , gcsArity = 1
    , gcsFlags = ["READONLY", "TOUCHES_ARBITRARY_KEYS"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["READONLY"]
    , gcsArity = 1
    , gcsFlags = ["FAST", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["READWRITE"]
    , gcsArity = 1
    , gcsFlags = ["FAST", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["RENAME"]
    , gcsArity = 3
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "newkey"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["RENAMENX"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "newkey"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["REPLCONF"]
    , gcsArity = -1
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["REPLICAOF"]
    , gcsArity = 3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "args"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "host-port"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "host"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "integer"
                              , gaName = "port"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "no-one"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "no"
                              , gaToken = Just "NO"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "one"
                              , gaToken = Just "ONE"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["RESET"]
    , gcsArity = 1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "NO_AUTH", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["RESTORE"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "ttl"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "serialized-value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "replace"
            , gaToken = Just "REPLACE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "absttl"
            , gaToken = Just "ABSTTL"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "seconds"
            , gaToken = Just "IDLETIME"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "frequency"
            , gaToken = Just "FREQ"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["RESTORE-ASKING"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM", "ASKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "ttl"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "serialized-value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "replace"
            , gaToken = Just "REPLACE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "absttl"
            , gaToken = Just "ABSTTL"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "seconds"
            , gaToken = Just "IDLETIME"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "frequency"
            , gaToken = Just "FREQ"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ROLE"]
    , gcsArity = 1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["RPOP"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["RPOPLPUSH"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["RPUSH"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["RPUSHX"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "element"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SADD"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SAVE"]
    , gcsArity = 1
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT", "NO_MULTI"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCAN"]
    , gcsArity = -2
    , gcsFlags = ["READONLY", "TOUCHES_ARBITRARY_KEYS"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "cursor"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Just "MATCH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "type"
            , gaToken = Just "TYPE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCARD"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT", "DEBUG"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "mode"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "yes"
                      , gaToken = Just "YES"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sync"
                      , gaToken = Just "SYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "no"
                      , gaToken = Just "NO"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT", "EXISTS"]
    , gcsArity = -3
    , gcsFlags = ["NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "sha1"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT", "FLUSH"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "flush-type"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "async"
                      , gaToken = Just "ASYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sync"
                      , gaToken = Just "SYNC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT", "KILL"]
    , gcsArity = 2
    , gcsFlags = ["NOSCRIPT", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SCRIPT", "LOAD"]
    , gcsArity = 3
    , gcsFlags = ["NOSCRIPT", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "script"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SDIFF"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SDIFFSTORE"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SELECT"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "index"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "CKQUORUM"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "CONFIG"]
    , gcsArity = -4
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "action"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "set"
                      , gaToken = Just "SET"
                      , gaOptional = False
                      , gaMultiple = True
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "parameter"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "value"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "parameter"
                      , gaToken = Just "GET"
                      , gaOptional = False
                      , gaMultiple = True
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "DEBUG"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "parameter"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "FAILOVER"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "FLUSHCONFIG"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "GET-MASTER-ADDR-BY-NAME"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "INFO-CACHE"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "nodename"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "IS-MASTER-DOWN-BY-ADDR"]
    , gcsArity = 6
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "ip"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "port"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "current-epoch"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "runid"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "MASTER"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "MASTERS"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "MONITOR"]
    , gcsArity = 6
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "ip"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "port"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "quorum"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "MYID"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "PENDING-SCRIPTS"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "REMOVE"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "REPLICAS"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "RESET"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "SENTINELS"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "SET"]
    , gcsArity = -5
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "option"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "SIMULATE-FAILURE"]
    , gcsArity = -3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "mode"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "crash-after-election"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "crash-after-promotion"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "help"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SENTINEL", "SLAVES"]
    , gcsArity = 3
    , gcsFlags = ["ADMIN", "SENTINEL", "ONLY_SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "master-name"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SET"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "get"
            , gaToken = Just "GET"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "expiration"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "integer"
                      , gaName = "seconds"
                      , gaToken = Just "EX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "integer"
                      , gaName = "milliseconds"
                      , gaToken = Just "PX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "unix-time"
                      , gaName = "unix-time-seconds"
                      , gaToken = Just "EXAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "unix-time"
                      , gaName = "unix-time-milliseconds"
                      , gaToken = Just "PXAT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "keepttl"
                      , gaToken = Just "KEEPTTL"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SETBIT"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "offset"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SETEX"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "seconds"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SETNX"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SETRANGE"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "offset"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "value"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SHUTDOWN"]
    , gcsArity = -1
    , gcsFlags = ["ADMIN", "NOSCRIPT", "LOADING", "STALE", "NO_MULTI", "SENTINEL", "ALLOW_BUSY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "save-selector"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nosave"
                      , gaToken = Just "NOSAVE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "save"
                      , gaToken = Just "SAVE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "now"
            , gaToken = Just "NOW"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "force"
            , gaToken = Just "FORCE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "abort"
            , gaToken = Just "ABORT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SINTER"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SINTERCARD"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SINTERSTORE"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SISMEMBER"]
    , gcsArity = 3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SLAVEOF"]
    , gcsArity = 3
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NOSCRIPT", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "args"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "host-port"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "string"
                              , gaName = "host"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "integer"
                              , gaName = "port"
                              , gaToken = Nothing
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "block"
                      , gaName = "no-one"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren =
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "no"
                              , gaToken = Just "NO"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              },
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "one"
                              , gaToken = Just "ONE"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SLOWLOG"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SLOWLOG", "GET"]
    , gcsArity = -2
    , gcsFlags = ["ADMIN", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SLOWLOG", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SLOWLOG", "LEN"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SLOWLOG", "RESET"]
    , gcsArity = 2
    , gcsFlags = ["ADMIN", "LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["SMEMBERS"]
    , gcsArity = 2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SMISMEMBER"]
    , gcsArity = -3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SMOVE"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "source"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SORT"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "by-pattern"
            , gaToken = Just "BY"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "get-pattern"
            , gaToken = Just "GET"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "sorting"
            , gaToken = Just "ALPHA"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Just "STORE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Just 2
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SORT_RO"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "by-pattern"
            , gaToken = Just "BY"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "get-pattern"
            , gaToken = Just "GET"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "order"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "asc"
                      , gaToken = Just "ASC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "desc"
                      , gaToken = Just "DESC"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "sorting"
            , gaToken = Just "ALPHA"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SPOP"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SPUBLISH"]
    , gcsArity = 3
    , gcsFlags = ["PUBSUB", "LOADING", "STALE", "FAST", "MAY_REPLICATE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "shardchannel"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "message"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SRANDMEMBER"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SREM"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SSCAN"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "cursor"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Just "MATCH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SSUBSCRIBE"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "shardchannel"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["STRLEN"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SUBSCRIBE"]
    , gcsArity = -2
    , gcsFlags = ["PUBSUB", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "channel"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SUBSTR"]
    , gcsArity = 4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "end"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SUNION"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SUNIONSTORE"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SUNSUBSCRIBE"]
    , gcsArity = -1
    , gcsFlags = ["PUBSUB", "NOSCRIPT", "LOADING", "STALE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "shardchannel"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SWAPDB"]
    , gcsArity = 3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "index1"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "index2"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["SYNC"]
    , gcsArity = 1
    , gcsFlags = ["NO_ASYNC_LOADING", "ADMIN", "NO_MULTI", "NOSCRIPT"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["TIME"]
    , gcsArity = 1
    , gcsFlags = ["LOADING", "STALE", "FAST"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["TOUCH"]
    , gcsArity = -2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["TTL"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["TYPE"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["UNLINK"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["UNSUBSCRIBE"]
    , gcsArity = -1
    , gcsFlags = ["PUBSUB", "NOSCRIPT", "LOADING", "STALE", "SENTINEL"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "string"
            , gaName = "channel"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["UNWATCH"]
    , gcsArity = 1
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "ALLOW_BUSY"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["WAIT"]
    , gcsArity = 3
    , gcsFlags = []
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numreplicas"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["WAITAOF"]
    , gcsArity = 4
    , gcsFlags = ["NOSCRIPT"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numlocal"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numreplicas"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "timeout"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["WATCH"]
    , gcsArity = -2
    , gcsFlags = ["NOSCRIPT", "LOADING", "STALE", "FAST", "ALLOW_BUSY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XACK"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "ID"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XADD"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "nomkstream"
            , gaToken = Just "NOMKSTREAM"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "trim"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "oneof"
                    , gaName = "strategy"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives =
                        [
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "maxlen"
                              , gaToken = Just "MAXLEN"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ],
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "minid"
                              , gaToken = Just "MINID"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                        ]
                    },
                  GeneratedArgument
                    { gaType = "oneof"
                    , gaName = "operator"
                    , gaToken = Nothing
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives =
                        [
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "equal"
                              , gaToken = Just "="
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ],
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "approximately"
                              , gaToken = Just "~"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                        ]
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "threshold"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "LIMIT"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "id-selector"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "auto-id"
                      , gaToken = Just "*"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "id"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "field"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "value"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XAUTOCLAIM"]
    , gcsArity = -6
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "consumer"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min-idle-time"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "justid"
            , gaToken = Just "JUSTID"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XCLAIM"]
    , gcsArity = -6
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "consumer"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min-idle-time"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "ID"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "ms"
            , gaToken = Just "IDLE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "unix-time"
            , gaName = "unix-time-milliseconds"
            , gaToken = Just "TIME"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "RETRYCOUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "force"
            , gaToken = Just "FORCE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "justid"
            , gaToken = Just "JUSTID"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "lastid"
            , gaToken = Just "LASTID"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XDEL"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "ID"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP", "CREATE"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "id-selector"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "id"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "new-id"
                      , gaToken = Just "$"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "mkstream"
            , gaToken = Just "MKSTREAM"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "entries-read"
            , gaToken = Just "ENTRIESREAD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP", "CREATECONSUMER"]
    , gcsArity = 5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "consumer"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP", "DELCONSUMER"]
    , gcsArity = 5
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "consumer"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP", "DESTROY"]
    , gcsArity = 4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["XGROUP", "SETID"]
    , gcsArity = -5
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "id-selector"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "string"
                      , gaName = "id"
                      , gaToken = Nothing
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "new-id"
                      , gaToken = Just "$"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "entriesread"
            , gaToken = Just "ENTRIESREAD"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XINFO"]
    , gcsArity = -2
    , gcsFlags = []
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["XINFO", "CONSUMERS"]
    , gcsArity = 4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XINFO", "GROUPS"]
    , gcsArity = 3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XINFO", "HELP"]
    , gcsArity = 2
    , gcsFlags = ["LOADING", "STALE"]
    , gcsArguments = []
    },
  GeneratedCommandSpec
    { gcsTokens = ["XINFO", "STREAM"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "full-block"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "full"
                    , gaToken = Just "FULL"
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "COUNT"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XLEN"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XPENDING"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "group"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "filters"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "min-idle-time"
                    , gaToken = Just "IDLE"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "start"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "end"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "consumer"
                    , gaToken = Nothing
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XRANGE"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "end"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XREAD"]
    , gcsArity = -4
    , gcsFlags = ["BLOCKING", "READONLY", "BLOCKING"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "milliseconds"
            , gaToken = Just "BLOCK"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "streams"
            , gaToken = Just "STREAMS"
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "key"
                    , gaName = "key"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = True
                    , gaKeySpecIndex = Just 0
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "ID"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = True
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XREADGROUP"]
    , gcsArity = -7
    , gcsFlags = ["BLOCKING", "WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "block"
            , gaName = "group-block"
            , gaToken = Just "GROUP"
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "group"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "consumer"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "milliseconds"
            , gaToken = Just "BLOCK"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "noack"
            , gaToken = Just "NOACK"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "streams"
            , gaToken = Just "STREAMS"
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "key"
                    , gaName = "key"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = True
                    , gaKeySpecIndex = Just 0
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "ID"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = True
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XREVRANGE"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "end"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XSETID"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "last-id"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "entries-added"
            , gaToken = Just "ENTRIESADDED"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "max-deleted-id"
            , gaToken = Just "MAXDELETEDID"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["XTRIM"]
    , gcsArity = -4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "trim"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "oneof"
                    , gaName = "strategy"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives =
                        [
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "maxlen"
                              , gaToken = Just "MAXLEN"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ],
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "minid"
                              , gaToken = Just "MINID"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                        ]
                    },
                  GeneratedArgument
                    { gaType = "oneof"
                    , gaName = "operator"
                    , gaToken = Nothing
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives =
                        [
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "equal"
                              , gaToken = Just "="
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ],
                          [
                            GeneratedArgument
                              { gaType = "pure-token"
                              , gaName = "approximately"
                              , gaToken = Just "~"
                              , gaOptional = False
                              , gaMultiple = False
                              , gaKeySpecIndex = Nothing
                              , gaChildren = []
                              , gaAlternatives = []
                              }
                          ]
                        ]
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "threshold"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Just "LIMIT"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZADD"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "condition"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "nx"
                      , gaToken = Just "NX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "xx"
                      , gaToken = Just "XX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "comparison"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "gt"
                      , gaToken = Just "GT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "lt"
                      , gaToken = Just "LT"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "change"
            , gaToken = Just "CH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "increment"
            , gaToken = Just "INCR"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "data"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "double"
                    , gaName = "score"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "string"
                    , gaName = "member"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZCARD"]
    , gcsArity = 2
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZCOUNT"]
    , gcsArity = 4
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZDIFF"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZDIFFSTORE"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZINCRBY"]
    , gcsArity = 4
    , gcsFlags = ["WRITE", "DENYOOM", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "increment"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZINTER"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "weight"
            , gaToken = Just "WEIGHTS"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "aggregate"
            , gaToken = Just "AGGREGATE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sum"
                      , gaToken = Just "SUM"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "min"
                      , gaToken = Just "MIN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "max"
                      , gaToken = Just "MAX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZINTERCARD"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZINTERSTORE"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "weight"
            , gaToken = Just "WEIGHTS"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "aggregate"
            , gaToken = Just "AGGREGATE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sum"
                      , gaToken = Just "SUM"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "min"
                      , gaToken = Just "MIN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "max"
                      , gaToken = Just "MAX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZLEXCOUNT"]
    , gcsArity = 4
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZMPOP"]
    , gcsArity = -4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "where"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "min"
                      , gaToken = Just "MIN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "max"
                      , gaToken = Just "MAX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZMSCORE"]
    , gcsArity = -3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZPOPMAX"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZPOPMIN"]
    , gcsArity = -2
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZRANDMEMBER"]
    , gcsArity = -2
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "options"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "pure-token"
                    , gaName = "withscores"
                    , gaToken = Just "WITHSCORES"
                    , gaOptional = True
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZRANGE"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "stop"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "sortby"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "byscore"
                      , gaToken = Just "BYSCORE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "bylex"
                      , gaToken = Just "BYLEX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "rev"
            , gaToken = Just "REV"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZRANGEBYLEX"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZRANGEBYSCORE"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZRANGESTORE"]
    , gcsArity = -5
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "dst"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "src"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "sortby"
            , gaToken = Nothing
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "byscore"
                      , gaToken = Just "BYSCORE"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "bylex"
                      , gaToken = Just "BYLEX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "rev"
            , gaToken = Just "REV"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZRANK"]
    , gcsArity = -3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscore"
            , gaToken = Just "WITHSCORE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREM"]
    , gcsArity = -3
    , gcsFlags = ["WRITE", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREMRANGEBYLEX"]
    , gcsArity = 4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREMRANGEBYRANK"]
    , gcsArity = 4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "stop"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREMRANGEBYSCORE"]
    , gcsArity = 4
    , gcsFlags = ["WRITE"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREVRANGE"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "start"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "stop"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREVRANGEBYLEX"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREVRANGEBYSCORE"]
    , gcsArity = -4
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "max"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "double"
            , gaName = "min"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "block"
            , gaName = "limit"
            , gaToken = Just "LIMIT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren =
                [
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "offset"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    },
                  GeneratedArgument
                    { gaType = "integer"
                    , gaName = "count"
                    , gaToken = Nothing
                    , gaOptional = False
                    , gaMultiple = False
                    , gaKeySpecIndex = Nothing
                    , gaChildren = []
                    , gaAlternatives = []
                    }
                ]
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZREVRANK"]
    , gcsArity = -3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscore"
            , gaToken = Just "WITHSCORE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZSCAN"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "cursor"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "pattern"
            , gaName = "pattern"
            , gaToken = Just "MATCH"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "count"
            , gaToken = Just "COUNT"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZSCORE"]
    , gcsArity = 3
    , gcsFlags = ["READONLY", "FAST"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "string"
            , gaName = "member"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZUNION"]
    , gcsArity = -3
    , gcsFlags = ["READONLY"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "weight"
            , gaToken = Just "WEIGHTS"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "aggregate"
            , gaToken = Just "AGGREGATE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sum"
                      , gaToken = Just "SUM"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "min"
                      , gaToken = Just "MIN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "max"
                      , gaToken = Just "MAX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            },
          GeneratedArgument
            { gaType = "pure-token"
            , gaName = "withscores"
            , gaToken = Just "WITHSCORES"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            }
        ]
    },
  GeneratedCommandSpec
    { gcsTokens = ["ZUNIONSTORE"]
    , gcsArity = -4
    , gcsFlags = ["WRITE", "DENYOOM"]
    , gcsArguments =
        [
          GeneratedArgument
            { gaType = "key"
            , gaName = "destination"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Just 0
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "numkeys"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "key"
            , gaName = "key"
            , gaToken = Nothing
            , gaOptional = False
            , gaMultiple = True
            , gaKeySpecIndex = Just 1
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "integer"
            , gaName = "weight"
            , gaToken = Just "WEIGHTS"
            , gaOptional = True
            , gaMultiple = True
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives = []
            },
          GeneratedArgument
            { gaType = "oneof"
            , gaName = "aggregate"
            , gaToken = Just "AGGREGATE"
            , gaOptional = True
            , gaMultiple = False
            , gaKeySpecIndex = Nothing
            , gaChildren = []
            , gaAlternatives =
                [
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "sum"
                      , gaToken = Just "SUM"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "min"
                      , gaToken = Just "MIN"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ],
                  [
                    GeneratedArgument
                      { gaType = "pure-token"
                      , gaName = "max"
                      , gaToken = Just "MAX"
                      , gaOptional = False
                      , gaMultiple = False
                      , gaKeySpecIndex = Nothing
                      , gaChildren = []
                      , gaAlternatives = []
                      }
                  ]
                ]
            }
        ]
    }
  ]
