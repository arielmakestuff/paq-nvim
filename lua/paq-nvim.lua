-- Constants
local PATH    = vim.fn.stdpath('data') .. '/site/pack/paqs/'
local GITHUB  = 'https://github.com/'
local REPO_RE = '^[%w-]+/([%w-_.]+)$'

local uv = vim.loop -- Alias for Neovim's event loop (libuv)
local packages = {} -- Table of 'name':{options} pairs
local run_hook      -- To handle mutual funtion recursion

local msgs = {
    clone = 'cloned',
    pull = 'pulled changes for',
    remove = 'removed',
    ['run hook for'] = 'ran hook for',
}

local num_pkgs = 0
local counters = {
    clone = {ok = 0, fail = 0},
    pull = {ok = 0, fail = 0},
    remove = {ok = 0, fail = 0},
}

local function inc(counter, result)
    counters[counter][result] = counters[counter][result] + 1
end

local function output_result(num, total, operation, name, ok)
    local result = ok and msgs[operation] or 'Failed to ' .. operation
    print(string.format('Paq [%d/%d] %s %s', num, total, result, name))
    --TODO: Write log
    return ok
end

local function count_ops(operation, name, ok)
    local op = counters[operation]
    local result = ok and 'ok' or 'fail'
    inc(operation, result)
    output_result(op[result], num_pkgs, operation, name,  ok)
    if op.ok + op.fail == num_pkgs then
        op.ok, op.fail = 0, 0
        vim.cmd 'packloadall! | helptags ALL'
    end
    return ok
end

local function call_proc(process, pkg, args, cwd, ishook)
    local handle, t
    handle =
        uv.spawn(process, {args=args, cwd=cwd},
            vim.schedule_wrap( function (code)
                handle:close()
                if not ishook then --(to prevent infinite recursion)
                    run_hook(pkg) --maybe NO-OP
                    count_ops(args[1] or process, pkg.name, code == 0)
                else --hooks aren't counted
                    output_result(0, 0, 'run hook for', pkg.name, code == 0)
                end
            end)
        )
end

function run_hook(pkg) --(already defined as local)
    local t = type(pkg.hook)
    if t == 'function' then
        local ok = pcall(pkg.hook)
        output_result(0, 0, 'run hook for', pkg.name, ok)
    elseif t == 'string' then
        local process
        local args = {}
        for word in pkg.hook:gmatch("%S+") do
            table.insert(args, word)
        end
        process = table.remove(args, 1)
        call_proc(process, pkg, args, pkg.dir, true)
    end
end

local function install_pkg(pkg)
    local install_args = {'clone', pkg.url}
    if pkg.exists then return inc('clone', 'ok') end
    if pkg.branch then
        vim.list_extend(install_args, {'-b',  pkg.branch})
    end
    vim.list_extend(install_args, {pkg.dir})
    call_proc('git', pkg, install_args)
end

local function update_pkg(pkg)
    if pkg.exists then
        call_proc('git', pkg, {'pull'}, pkg.dir)
    end
end

local function rmdir(dir, is_pack_dir) --pack_dir = start | opt
    local name, t, child, ok
    local handle = uv.fs_scandir(dir)
    while handle do
        name, t = uv.fs_scandir_next(handle)
        if not name then break end
        child = dir .. '/' .. name
        if is_pack_dir then --check which packages are listed
            if packages[name] then --do nothing
                ok = true
            else --package isn't listed, remove it
                ok = rmdir(child)
                count_ops('remove', name, ok)
            end
        else --it's an arbitrary directory or file
            ok = (t == 'directory') and rmdir(child) or uv.fs_unlink(child)
        end
        if not ok then return end
    end
    return is_pack_dir or uv.fs_rmdir(dir) --don't delete start/opt
end

local function paq(args)
    if type(args) == 'string' then args = {args} end

    num_pkgs = num_pkgs + 1

    local reponame = args[1]:match(REPO_RE)
    if not reponame then
        return output_result(num_pkgs, num_pkgs, 'parse', args[1])
    end

    local dir = PATH .. (args.opt and 'opt/' or 'start/') .. reponame

    packages[reponame] = {
        name   = reponame,
        branch = args.branch,
        dir    = dir,
        exists = (vim.fn.isdirectory(dir) ~= 0),
        hook   = args.hook,
        url    = args.url or GITHUB .. args[1] .. '.git',
    }
end

local function setup_path(pathstr)
    if (pathstr == nil) then
        return
    end

    local arg_type = type(pathstr)
    if (arg_type ~= 'string') then
        error('path arg expected type string, got ' .. arg_type)
    end

    local last_char = PATH:sub(#pathstr, #pathstr)
    local sep = package.config:sub(1, 1)
    if (last_char ~= '/' and last_char ~= sep) then
        pathstr = pathstr .. sep
    end

    vim.fn.mkdir(pathstr, 'p')
    PATH = pathstr
end

return {
    setup_path   = setup_path,
    install = function() vim.tbl_map(install_pkg, packages) end,
    update  = function() vim.tbl_map(update_pkg, packages) end,
    clean   = function() rmdir(PATH..'start', 1); rmdir(PATH..'opt', 1) end,
    paq     = paq,
}
