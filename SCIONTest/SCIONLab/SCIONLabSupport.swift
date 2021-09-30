//
//  SCIONLabSupport.swift
//  SCIONTest
//  Copyright Jonas Gessner
//  Created by Jonas Gessner on 12.04.21.
//

import Foundation

struct SCIONLab_AWS_Hell_AP_Topology: TopologyTemplate {
    let name = "AWS Hell"
    
    func generateTopology(for parameters: TopologyParameters) -> String {
        return
            """
{
    "attributes": [],
    "border_routers": {
        "br-1": {
            "ctrl_addr": "\(parameters.borderRouter):30201",
            "interfaces": {
                "1": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:ede",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "2": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:ede",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "3": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:ede",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "4": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:ede",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "5": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:ede",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                }
            },
            "internal_addr": "\(parameters.borderRouter):30001"
        }
    },
    "control_service": {
        "cs-1": {
            "addr": "\(parameters.borderRouter):30254"
        }
    },
    "discovery_service": {
        "ds-1": {
            "addr": "\(parameters.borderRouter):30254"
        }
    },
    "isd_as": "16-ffaa:1:f04",
    "mtu": 1472,
    "sigs": {
        "sig-1": {
            "ctrl_addr": "\(parameters.borderRouter):30256",
            "data_addr": "\(parameters.borderRouter):30056"
        }
    }
}
"""
    }
}

struct SCIONLab_AWS_AP_Topology: TopologyTemplate {
    let name = "AWS"
    
    func generateTopology(for parameters: TopologyParameters) -> String {
        return
"""
{
    "attributes": [],
    "border_routers": {
        "br-1": {
            "ctrl_addr": "\(parameters.borderRouter):30201",
            "interfaces": {
                "1": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:0:1002",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "2": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:0:1002",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "3": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:0:1002",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "4": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:0:1002",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "5": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:0:1002",
                  "link_to": "PARENT",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "6": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:f04",
                  "link_to": "CHILD",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "7": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:f04",
                  "link_to": "CHILD",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "8": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:f04",
                  "link_to": "CHILD",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "9": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:f04",
                  "link_to": "CHILD",
                  "mtu": 1472,
                  "underlay": {
                  }
                },
                "10": {
                  "bandwidth": 1000,
                  "isd_as": "16-ffaa:1:f04",
                  "link_to": "CHILD",
                  "mtu": 1472,
                  "underlay": {
                  }
                }
            },
            "internal_addr": "\(parameters.borderRouter):30001"
        }
    },
    "control_service": {
        "cs-1": {
            "addr": "\(parameters.borderRouter):30254"
        }
    },
    "discovery_service": {
        "ds-1": {
            "addr": "\(parameters.borderRouter):30254"
        }
    },
    "isd_as": "16-ffaa:1:ede",
    "mtu": 1472,
    "sigs": {
        "sig-1": {
            "ctrl_addr": "\(parameters.borderRouter):30256",
            "data_addr": "\(parameters.borderRouter):30056"
        }
    }
}
"""
    }
}

struct SCIONLab_ETH_Topology: TopologyTemplate {
    let name = "ETH Direct"
    
    func generateTopology(for parameters: TopologyParameters) -> String {
        return """
{
  "attributes": [],
  "border_routers": {
    "br-1": {
      "ctrl_addr": "192.33.92.146:30201",
      "interfaces": {
        "2": {
          "bandwidth": 1000,
          "isd_as": "17-ffaa:0:1108",
          "link_to": "PARENT",
          "mtu": 1472,
          "underlay": {
          }
        }
      },
      "internal_addr": "192.33.92.146:30001"
    },
    "br-2": {
      "ctrl_addr": "192.33.92.68:30202",
      "interfaces": {
        "3": {
          "bandwidth": 1000,
          "isd_as": "17-ffaa:0:1108",
          "link_to": "PARENT",
          "mtu": 1472,
          "underlay": {
          }
        }
      },
      "internal_addr": "192.33.92.68:30002"
    },
    "br-3": {
      "ctrl_addr": "129.132.121.164:30203",
      "interfaces": {
        "1": {
          "bandwidth": 1000,
          "isd_as": "17-ffaa:0:1110",
          "link_to": "CHILD",
          "mtu": 1472,
          "underlay": {
          }
        },
        "4": {
          "bandwidth": 1000,
          "isd_as": "17-ffaa:0:1107",
          "link_to": "CHILD",
          "mtu": 1472,
          "underlay": {
          }
        }
      },
      "internal_addr": "129.132.121.164:30003"
    }
  },
  "control_service": {
    "cs-1": {
      "addr": "129.132.121.164:30254"
    }
  },
  "discovery_service": {
    "ds-1": {
      "addr": "129.132.121.164:30254"
    }
  },
  "isd_as": "17-ffaa:0:1102",
  "mtu": 1472,
  "sigs": {
    "sig-1": {
      "ctrl_addr": "129.132.121.163:30256",
      "data_addr": "129.132.121.163:30056"
    }
  }
}
"""
    }
}
