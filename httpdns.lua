-- httpdns.lua
local _M = {_VERSION = "0.1"}

-- constants
local MYSQL_HOST = "127.0.0.1"
local MYSQL_PORT = 3306
local MYSQL_DATABASE = "ngx_test"
local MYSQL_USER = "ngx_test"
local MYSQL_PASSWORD = "ngx_test"
local MYSQL_CHARSET = "utf8"

local REDIS_HOST = "127.0.0.1"
local REDIS_PORT = 6379

local function connect_redis()
    local redis = require "resty.redis"
    local red = redis:new()
    
    red:set_timeout(1000) -- 1 sec
    local ok, err = red:connect(REDIS_HOST, REDIS_PORT)
    if not ok then
        ngx.log(ngx.OK, "failed to connect: ", err)
        ngx.exit(500)
    end
    
    ngx.log(ngx.OK, "connected to redis.")
    return red
end

local function release_connect_redis(red)
    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.OK, "failed to set keepalive: ", err)
        return false
    end
    return true
end

local function release_connect_mysql(db)
    local ok, err = db:set_keepalive(10000, 100)
    if not ok then
        ngx.log(ngx.OK, "failed to set keepalive: ", err)
        return false
    end
    return true
end

local function connect_mysql()
    local mysql = require "resty.mysql"
    local db, err = mysql:new()
    if not db then
        ngx.log(ngx.OK, "failed to instantiate mysql: ", err)
        ngx.exit(500)
    end
    
    db:set_timeout(1000) -- 1 sec
    local ok, err, errcode, sqlstate = db:connect{
        host = MYSQL_HOST,
        port = MYSQL_PORT,
        database = MYSQL_DATABASE,
        user = MYSQL_USER,
        password = MYSQL_PASSWORD,
        charset = MYSQL_CHARSET,
        max_packet_size = 1024 * 1024,
    }
    
    if not ok then
        ngx.log(ngx.OK, "failed to connect: ", err, ": ", errcode, " ", sqlstate)
        ngx.exit(500)
    end
    
    ngx.log(ngx.OK, "connected to mysql.")
    return db
end

local function connect_dns()
    local resolver = require "resty.dns.resolver"
    local r, err = resolver:new{
        nameservers = {"1.1.1.1", {"8.8.4.4", 53} },
        retrans = 5,  -- 5 retransmissions on receive timeout
        timeout = 2000,  -- 2 sec
    }
    
    if not r then
        ngx.log(ngx.OK, "failed to instantiate the resolver: ", err)
        ngx.exit(500)
    end
    
    ngx.log(ngx.OK, "connected to dns.")
    return r
end

function _M.get_cache(key)
    local red = connect_redis()
    local res, err = red:get(cache_key)
    if not res then
        return nil
    end

    release_connect_redis(red)
    if res ~= ngx.null then
        return res
    end
end

function _M.set_cache(key, val)
    local red = connect_redis()
    ok, err = red:set(key, val)
    if not ok then
        ngx.log(ngx.OK, "failed to set cache: ", err)
        return false
    end
    release_connect_redis(red)
    return true
end

function _M.find_ip(uid)
    local region_ip
    local db = connect_mysql()
    res, err, errcode, sqlstate =
        db:query("SELECT region_ip FROM HTTPDNS WHERE uid = " .. uid)
    if res and next(res) ~=nil then
        region_ip = res[1].region_ip
    end
    release_connect_mysql(db)
    return region_ip
end

function _M.update_ip(uid, ip)
    local db = connect_mysql()
    local res, err, errcode, sqlstate =
    db:query("INSERT INTO HTTPDNS (uid, region_ip) VALUE (" .. uid .. ", '" .. ip .. "')")
    if not res then
        ngx.log(ngx.OK, "bad result: ", err, ": ", errcode, ": ", sqlstate, ".")
        return false
    end
    release_connect_mysql(db)
    return true
end

function _M.find_dns(domain)
    local r = connect_dns()
    local answers, err, tries = r:query(domain, nil, {})
    if not answers then
        ngx.log(ngx.OK, "failed to query the DNS server: ", err)
        ngx.log(ngx.OK, "retry historie:\n  ", table.concat(tries, "\n  "))
        return nil
    end

    if answers.errcode then
        ngx.log(ngx.OK, "server returned error code: ", answers.errcode,
                ": ", answers.errstr)
        return nil
    end

    local region_ip
    for i, ans in ipairs(answers) do
        region_ip = ans.address
    end
    return region_ip
end

return _M