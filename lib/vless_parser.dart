import 'dart:convert';

class VlessParser {
  
  static String getName(String vlessLink) {
    try {
      if (!vlessLink.contains("#")) return "Server";
      String rawName = vlessLink.split("#").last;
      return Uri.decodeComponent(rawName);
    } catch (e) {
      return "Unknown Server";
    }
  }

  static String? getAppGroup(String vlessLink) {
    try {
      if (!vlessLink.contains("?")) return null;
      
      String query = vlessLink.split("?")[1];
      if (query.contains("#")) {
        query = query.split("#")[0];
      }

      var pairs = query.split("&");
      for (var pair in pairs) {
        var kv = pair.split("=");
        if (kv.length == 2 && kv[0] == "app_group") {
          return kv[1].trim().toLowerCase();
        }
      }
    } catch (e) {
      return null;
    }
    return null;
  }

  static Map<String, dynamic>? getTarget(String vlessLink) {
    try {
      if (!vlessLink.startsWith("vless://")) return null;
      
      String raw = vlessLink.substring(8); 
      
      if (raw.contains("#")) raw = raw.split("#")[0];
      if (raw.contains("?")) raw = raw.split("?")[0];

      var parts = raw.split("@");
      if (parts.length < 2) return null;
      
      String hostPort = parts[1];

      String address = "";
      int port = 443;

      if (hostPort.startsWith("[")) {
        int closeBracket = hostPort.lastIndexOf("]");
        address = hostPort.substring(1, closeBracket);
        port = int.parse(hostPort.substring(closeBracket + 2));
      } else {
        var p = hostPort.split(":");
        address = p[0];
        port = int.parse(p[1]);
      }
      
      return {"address": address, "port": port};
    } catch (e) {
      return null;
    }
  }

  static String generateConfig(String vlessLink) {
    if (!vlessLink.startsWith("vless://")) {
      throw Exception("Это не VLESS ссылка");
    }

    String raw = vlessLink.substring(8);
    
    String content = raw;
    if (raw.contains("#")) {
      content = raw.split("#")[0];
    }

    String mainPart = content;
    String queryPart = "";
    if (content.contains("?")) {
      var parts = content.split("?");
      mainPart = parts[0];
      queryPart = parts[1];
    }

    var userInfoParts = mainPart.split("@");
    if (userInfoParts.length != 2) throw Exception("Неверный формат user@host");
    
    String uuid = userInfoParts[0];
    String hostPort = userInfoParts[1];
    
    String address = "";
    int port = 443;
    
    if (hostPort.startsWith("[")) {
      int closeBracket = hostPort.lastIndexOf("]");
      address = hostPort.substring(1, closeBracket);
      port = int.parse(hostPort.substring(closeBracket + 2));
    } else {
      var parts = hostPort.split(":");
      address = parts[0];
      port = int.parse(parts[1]);
    }

    Map<String, String> query = {};
    if (queryPart.isNotEmpty) {
      var pairs = queryPart.split("&");
      for (var pair in pairs) {
        var kv = pair.split("=");
        if (kv.length == 2) {
          query[kv[0]] = Uri.decodeComponent(kv[1]);
        }
      }
    }

    String type = query["type"] ?? "tcp";
    String security = query["security"] ?? "none";
    String sni = query["sni"] ?? "";
    String pbk = query["pbk"] ?? ""; 
    String fp = query["fp"] ?? "";   
    String sid = query["sid"] ?? ""; 
    String path = query["path"] ?? "/";
    String host = query["host"] ?? "";
    String flow = query["flow"] ?? "";

    // ✅ УМНЫЙ MUX: Включается только для Cloudflare (WS/gRPC) и защищает от перегрузок TLS.
    // На XTLS (обычные серверы) отключается, чтобы не было крашей.
    bool isWsOrGrpc = (type == "ws" || type == "grpc");
    bool isXtls = flow.contains("xtls");
    bool enableMux = isWsOrGrpc && !isXtls;

    Map<String, dynamic> streamSettings = {
      "network": type,
      "security": security,
      // ✅ ГЛАВНОЕ ОРУЖИЕ ПРОТИВ ОТВАЛОВ НА LTE:
      // Заставляем ОС слать невидимый "пульс" на мобильную вышку
      "sockopt": {
        "tcpKeepAliveIdle": 30,     // Если интернет простаивает 30 секунд...
        "tcpKeepAliveInterval": 15  // ...начинаем слать пинг каждые 15 секунд
      }
    };

    if (type == "ws") {
      streamSettings["wsSettings"] = {
        "path": path,
        "headers": host.isNotEmpty ? {"Host": host} : {}
      };
    } else if (type == "grpc") {
       streamSettings["grpcSettings"] = {
        "serviceName": query["serviceName"] ?? ""
      };
    }

    if (security == "tls") {
      streamSettings["tlsSettings"] = {
        "serverName": sni,
        "allowInsecure": false,
        "fingerprint": fp.isNotEmpty ? fp : "chrome"
      };
    } else if (security == "reality") {
      streamSettings["realitySettings"] = {
        "show": false,
        "fingerprint": fp.isNotEmpty ? fp : "chrome",
        "serverName": sni,
        "publicKey": pbk,
        "shortId": sid,
        "spiderX": ""
      };
    }

    Map<String, dynamic> config = {
      "log": {
        "loglevel": "warning"
      },
      "dns": {
        "queryStrategy": "UseIPv4",
        "servers": [
          "https://1.1.1.1/dns-query",
          "https://8.8.8.8/dns-query",
          "localhost"
        ]
      },
      "inbounds": [
        {
          "tag": "socks",
          "port": 10808,
          "listen": "127.0.0.1",
          "protocol": "socks",
          "settings": {"udp": true},
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"] 
          }
        },
        {
          "tag": "http",
          "port": 10809,
          "listen": "127.0.0.1",
          "protocol": "http",
          "sniffing": {
            "enabled": true,
            "destOverride": ["http", "tls", "quic"]
          }
        }
      ],
      "outbounds": [
        {
          "tag": "proxy",
          "protocol": "vless",
          "settings": {
            "vnext": [
              {
                "address": address,
                "port": port,
                "users": [
                  {
                    "id": uuid,
                    "encryption": "none",
                    "level": 0,
                    "flow": flow
                  }
                ]
              }
            ]
          },
          "streamSettings": streamSettings,
          "mux": {
            "enabled": enableMux,
            "concurrency": enableMux ? 8 : -1
          }
        },
        {
          "tag": "direct",
          "protocol": "freedom",
          "settings": {}
        },
        {
          "tag": "block",
          "protocol": "blackhole",
          "settings": {}
        },
        {
          "tag": "dns-out",
          "protocol": "dns",
          "settings": {}
        }
      ],
      "routing": {
        "domainStrategy": "AsIs",
        "rules": [
          // Блокируем QUIC (спасает от разрывов при просмотре YouTube/Insta через CF)
          {
            "type": "field",
            "network": "udp",
            "port": 443,
            "outboundTag": "block"
          },
          {
            "type": "field",
            "inboundTag": ["socks", "http"],
            "port": 53, 
            "network": "udp",
            "outboundTag": "dns-out"
          },
          {
            "type": "field",
            "ip": [
              "10.0.0.0/8",
              "172.16.0.0/12",
              "192.168.0.0/16",
              "127.0.0.0/8"
            ],
            "outboundTag": "direct"
          }
        ]
      }
    };

    return jsonEncode(config);
  }
}