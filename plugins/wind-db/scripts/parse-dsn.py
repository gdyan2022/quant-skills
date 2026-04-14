#!/usr/bin/env python3
"""
把用户粘贴的数据库连接串解析成 shell 可用的字段。

支持的输入格式（自动识别）：
  1. SQLAlchemy:  mssql+pyodbc://user:pass@host:1433/db?driver=ODBC
  2. 标准 URL:    sqlserver://user:pass@host:1433/db?sslmode=disable
  3. JDBC:        jdbc:sqlserver://host:1433;databaseName=db;user=x;password=y
                  jdbc:mysql://host:3306/db?user=x&password=y
  4. ADO.NET:     Server=host,1433;Database=db;User Id=x;Password=y;Encrypt=false
  5. 键值散列:    host=x port=y user=z password=w database=d dialect=mssql+pyodbc

输出：一行 shell 赋值语句，可直接 `eval` 到当前 shell：
  WIND_DB_DIALECT='mssql+pyodbc'
  WIND_DB_HOST='1.2.3.4'
  WIND_DB_PORT='1433'
  WIND_DB_USER='scott'
  WIND_DB_PASSWORD='tiger'
  WIND_DB_NAME='winddb'

失败时：stderr 打错误消息，exit 1。
"""
import re
import sys
import shlex
from urllib.parse import unquote, urlparse, parse_qs


# ── dialect 标准化 ────────────────────────────────────────
# 输入的 scheme（从 SQLAlchemy / URL / JDBC）映射到 .env 里的 WIND_DB_DIALECT 值
# （跟 .env.example 保持一致）
SCHEME_TO_DIALECT = {
    # MSSQL / SQL Server 家族
    "mssql": "mssql+pyodbc",
    "mssql+pyodbc": "mssql+pyodbc",
    "sqlserver": "mssql+pyodbc",
    "jdbc:sqlserver": "mssql+pyodbc",
    # MySQL
    "mysql": "mysql+pymysql",
    "mysql+pymysql": "mysql+pymysql",
    "jdbc:mysql": "mysql+pymysql",
    # MariaDB
    "mariadb": "mariadb+pymysql",
    "mariadb+pymysql": "mariadb+pymysql",
    "jdbc:mariadb": "mariadb+pymysql",
    # PostgreSQL
    "postgres": "postgresql+psycopg2",
    "postgresql": "postgresql+psycopg2",
    "postgresql+psycopg2": "postgresql+psycopg2",
    "jdbc:postgresql": "postgresql+psycopg2",
    # SQLite
    "sqlite": "sqlite",
    # Oracle（dbhub 不支持，但我们识别出来可以给清晰错误）
    "oracle": "oracle+cx_oracle",
    "oracle+cx_oracle": "oracle+cx_oracle",
    "jdbc:oracle:thin": "oracle+cx_oracle",
}

DEFAULT_PORTS = {
    "mssql+pyodbc": "1433",
    "mysql+pymysql": "3306",
    "mariadb+pymysql": "3306",
    "postgresql+psycopg2": "5432",
    "oracle+cx_oracle": "1521",
}


def die(msg):
    print(f"✗ 解析失败：{msg}", file=sys.stderr)
    sys.exit(1)


def normalize_dialect(scheme):
    s = scheme.lower().strip()
    if s in SCHEME_TO_DIALECT:
        return SCHEME_TO_DIALECT[s]
    # 尝试去掉 +driver 后缀
    head = s.split("+")[0]
    if head in SCHEME_TO_DIALECT:
        return SCHEME_TO_DIALECT[head]
    return None


def parse_jdbc(s):
    """
    jdbc:sqlserver://host:1433;databaseName=db;user=x;password=y
    jdbc:mysql://host:3306/db?user=x&password=y
    jdbc:postgresql://host:5432/db?user=x&password=y
    jdbc:oracle:thin:@//host:1521/service
    """
    # 识别 subprotocol
    m = re.match(r"^jdbc:([a-z]+)(?::([a-z]+))?:", s, re.IGNORECASE)
    if not m:
        return None
    sub = m.group(1).lower()
    if m.group(2):
        sub = f"{sub}:{m.group(2).lower()}"  # oracle:thin
    scheme_key = f"jdbc:{sub}"
    dialect = normalize_dialect(scheme_key)
    if not dialect:
        return None

    result = {"WIND_DB_DIALECT": dialect}

    # 剥掉 jdbc:xxx: 前缀后按两种方言分开处理
    body = s[m.end():]

    if scheme_key == "jdbc:sqlserver":
        # //host:1433;databaseName=db;user=x;password=y;key=val
        body = body.lstrip("/")
        parts = body.split(";")
        hostport = parts[0]
        if ":" in hostport:
            result["WIND_DB_HOST"], result["WIND_DB_PORT"] = hostport.split(":", 1)
        else:
            result["WIND_DB_HOST"] = hostport
        for p in parts[1:]:
            if "=" not in p:
                continue
            k, v = p.split("=", 1)
            kl = k.strip().lower()
            if kl == "databasename":
                result["WIND_DB_NAME"] = v
            elif kl == "user":
                result["WIND_DB_USER"] = v
            elif kl == "password":
                result["WIND_DB_PASSWORD"] = v
            elif kl == "instancename":
                result["WIND_DB_INSTANCE"] = v
        return result

    if scheme_key in ("jdbc:mysql", "jdbc:mariadb", "jdbc:postgresql"):
        # //host:3306/db?user=x&password=y  —— 跟普通 URL 一致，重用 urlparse
        return _parse_url_like(f"{dialect.split('+')[0]}:{body}", dialect)

    if scheme_key == "jdbc:oracle:thin":
        # @//host:1521/service 或 @host:1521:sid
        body = body.lstrip("@").lstrip("/")
        m2 = re.match(r"([^:/]+)(?::(\d+))?[:/](.+)", body)
        if not m2:
            return None
        result["WIND_DB_HOST"] = m2.group(1)
        result["WIND_DB_PORT"] = m2.group(2) or DEFAULT_PORTS.get(dialect, "1521")
        result["WIND_DB_NAME"] = m2.group(3)
        return result

    return None


def _parse_url_like(url, known_dialect=None):
    """
    scheme://[user[:pass]@]host[:port][/db][?query]
    兼容 SQLAlchemy 的 dialect+driver 前缀。
    """
    try:
        u = urlparse(url)
    except Exception as e:
        return None

    if not u.scheme:
        return None

    dialect = known_dialect or normalize_dialect(u.scheme)
    if not dialect:
        return None

    result = {"WIND_DB_DIALECT": dialect}
    if u.hostname:
        result["WIND_DB_HOST"] = u.hostname
    if u.port:
        result["WIND_DB_PORT"] = str(u.port)
    if u.username:
        result["WIND_DB_USER"] = unquote(u.username)
    if u.password:
        result["WIND_DB_PASSWORD"] = unquote(u.password)
    if u.path and u.path.lstrip("/"):
        result["WIND_DB_NAME"] = u.path.lstrip("/")

    # query 里的 user/password（MySQL JDBC 风格）
    if u.query:
        qs = parse_qs(u.query, keep_blank_values=True)
        if "user" in qs and "WIND_DB_USER" not in result:
            result["WIND_DB_USER"] = qs["user"][0]
        if "password" in qs and "WIND_DB_PASSWORD" not in result:
            result["WIND_DB_PASSWORD"] = qs["password"][0]
        if "sslmode" in qs:
            result["WIND_DB_SSLMODE"] = qs["sslmode"][0]
        if "instanceName" in qs:
            result["WIND_DB_INSTANCE"] = qs["instanceName"][0]

    return result


def parse_ado_dotnet(s):
    """
    Server=host,1433;Database=db;User Id=x;Password=y;Encrypt=false
    也处理 Data Source=host / Initial Catalog=db 等别名
    """
    if "=" not in s or ";" not in s:
        return None
    pairs = {}
    for part in s.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        k, v = part.split("=", 1)
        pairs[k.strip().lower()] = v.strip()

    if not pairs:
        return None

    # ADO.NET 一般默认是 SQL Server（除非能识别出别的）
    dialect = "mssql+pyodbc"
    result = {"WIND_DB_DIALECT": dialect}

    server = pairs.get("server") or pairs.get("data source") or pairs.get("host")
    if not server:
        return None
    # Server=host,port  或 Server=host:port
    m = re.match(r"([^,:]+)(?:[,:](\d+))?", server)
    result["WIND_DB_HOST"] = m.group(1)
    if m.group(2):
        result["WIND_DB_PORT"] = m.group(2)

    db = (pairs.get("database") or pairs.get("initial catalog")
          or pairs.get("dbname"))
    if db:
        result["WIND_DB_NAME"] = db
    user = pairs.get("user id") or pairs.get("uid") or pairs.get("user")
    if user:
        result["WIND_DB_USER"] = user
    pwd = pairs.get("password") or pairs.get("pwd")
    if pwd:
        result["WIND_DB_PASSWORD"] = pwd
    inst = pairs.get("instance") or pairs.get("instancename")
    if inst:
        result["WIND_DB_INSTANCE"] = inst
    enc = pairs.get("encrypt")
    if enc is not None:
        # Encrypt=true / false → sslmode=require / disable
        result["WIND_DB_SSLMODE"] = "require" if enc.lower() == "true" else "disable"
    return result


def parse_kv(s):
    """
    host=1.2.3.4 port=1433 user=scott password=tiger database=winddb dialect=mssql+pyodbc
    （空格或换行分隔）
    """
    try:
        tokens = shlex.split(s)
    except Exception:
        return None
    if not tokens:
        return None
    pairs = {}
    for t in tokens:
        if "=" not in t:
            continue
        k, v = t.split("=", 1)
        pairs[k.strip().lower()] = v.strip()
    if not pairs:
        return None

    # 至少要有 host 才算合法
    host = pairs.get("host") or pairs.get("server")
    if not host:
        return None

    # 推断 dialect
    d = pairs.get("dialect") or pairs.get("type") or pairs.get("driver")
    if d:
        dialect = normalize_dialect(d) or d
    else:
        return None  # 键值模式下必须显式给 dialect/type

    result = {"WIND_DB_DIALECT": dialect, "WIND_DB_HOST": host}
    if "port" in pairs:
        result["WIND_DB_PORT"] = pairs["port"]
    for k_in, k_out in [("user", "WIND_DB_USER"), ("username", "WIND_DB_USER"),
                         ("password", "WIND_DB_PASSWORD"), ("pwd", "WIND_DB_PASSWORD"),
                         ("database", "WIND_DB_NAME"), ("db", "WIND_DB_NAME"),
                         ("dbname", "WIND_DB_NAME"),
                         ("sslmode", "WIND_DB_SSLMODE"),
                         ("instance", "WIND_DB_INSTANCE")]:
        if k_in in pairs and k_out not in result:
            result[k_out] = pairs[k_in]
    return result


def parse(s):
    s = s.strip()
    if not s:
        die("输入为空")

    if s.lower().startswith("jdbc:"):
        r = parse_jdbc(s)
        if r:
            return r
        die("看起来是 JDBC URL 但解析失败，请检查格式")

    if "://" in s:
        r = _parse_url_like(s)
        if r:
            return r
        die("看起来是 URL 形式但 scheme 不识别。支持的 scheme："
            + ", ".join(sorted(set(SCHEME_TO_DIALECT.keys()))))

    # ADO.NET 形式（Key=Value;Key=Value）
    if "=" in s and ";" in s and "://" not in s:
        r = parse_ado_dotnet(s)
        if r:
            return r

    # 键值对形式（空格分隔）
    r = parse_kv(s)
    if r:
        return r

    die("无法识别的格式。支持：SQLAlchemy URL / 标准 URL / JDBC / ADO.NET / 键值对")


def shell_quote(v):
    # 单引号包裹，内部 ' 转义为 '\''
    return "'" + v.replace("'", "'\\''") + "'"


def main():
    if len(sys.argv) > 1:
        # 命令行参数优先
        raw = sys.argv[1]
    else:
        # 从 stdin 读
        raw = sys.stdin.read()

    result = parse(raw)

    # 补默认端口
    if "WIND_DB_PORT" not in result and result.get("WIND_DB_DIALECT") in DEFAULT_PORTS:
        result["WIND_DB_PORT"] = DEFAULT_PORTS[result["WIND_DB_DIALECT"]]

    # 必需字段检查
    missing = []
    for f in ("WIND_DB_DIALECT", "WIND_DB_HOST"):
        if f not in result:
            missing.append(f)
    if missing:
        die(f"解析结果缺少必需字段: {', '.join(missing)}")

    # 输出 shell 赋值语句
    for k, v in result.items():
        print(f"{k}={shell_quote(v)}")


if __name__ == "__main__":
    main()
