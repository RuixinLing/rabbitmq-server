load("//bazel_erlang:erlang_home.bzl", "ErlangHomeProvider")
load("//bazel_erlang:elixir_home.bzl", "ElixirHomeProvider", "MixArchivesProvider")
load("//bazel_erlang:bazel_erlang_lib.bzl", "ErlangLibInfo", "path_join")
load("//bazel_erlang:ct.bzl", "lib_dir")
load(":rabbitmqctl.bzl", "MIX_DEPS_DIR")

def _impl(ctx):
    erlang_home = ctx.attr._erlang_home[ErlangHomeProvider].path
    elixir_home = ctx.attr._elixir_home[ElixirHomeProvider].path
    mix_archives = ctx.attr._mix_archives[MixArchivesProvider].path

    # when linked instead of copied, we encounter a bazel error such as
    # "A TreeArtifact may not contain relative symlinks whose target paths traverse outside of the TreeArtifact"
    copy_compiled_deps_commands = []
    copy_compiled_deps_commands.append("mkdir ${{TEST_UNDECLARED_OUTPUTS_DIR}}/{}".format(MIX_DEPS_DIR))
    for dep in ctx.attr.deps:
        info = dep[ErlangLibInfo]
        copy_compiled_deps_commands.append(
            "cp -R ${{PWD}}/{source} ${{TEST_UNDECLARED_OUTPUTS_DIR}}/{target}".format(
                source = lib_dir(dep),
                target = path_join(MIX_DEPS_DIR, info.lib_name)
            )
        )

    erl_libs = ":".join(
        [path_join("${TEST_SRCDIR}/__main__", lib_dir(dep)) for dep in ctx.attr.deps]
    )

    script = """
        set -euxo pipefail

        export LANG="en_US.UTF-8"
        export LC_ALL="en_US.UTF-8"

        export PATH=${{PATH}}:{erlang_home}/bin:{elixir_home}/bin

        INITIAL_DIR=${{PWD}}

        ln -s ${{PWD}}/{package_dir}/config ${{TEST_UNDECLARED_OUTPUTS_DIR}}
        ln -s ${{PWD}}/{package_dir}/include ${{TEST_UNDECLARED_OUTPUTS_DIR}}
        ln -s ${{PWD}}/{package_dir}/lib ${{TEST_UNDECLARED_OUTPUTS_DIR}}
        ln -s ${{PWD}}/{package_dir}/test ${{TEST_UNDECLARED_OUTPUTS_DIR}}
        ln -s ${{PWD}}/{package_dir}/mix.exs ${{TEST_UNDECLARED_OUTPUTS_DIR}}

        {copy_compiled_deps_command}

        cd ${{TEST_UNDECLARED_OUTPUTS_DIR}}

        export HOME=${{PWD}}
        export MIX_ARCHIVES={mix_archives}
        export DEPS_DIR={mix_deps_dir}
        mix local.rebar --force
        mix make_deps

        # due to https://github.com/elixir-lang/elixir/issues/7699 we
        # "run" the tests, but skip them all, in order to trigger
        # compilation of all *_test.exs files before we actually run them
        mix test --exclude test

        export TEST_TMPDIR=${{TEST_UNDECLARED_OUTPUTS_DIR}}

        # we need a running broker with certain plugins for this to pass 
        trap 'catch $?' EXIT
        catch() {{
            pid=$(cat ${{TEST_TMPDIR}}/*/*.pid)
            kill -TERM "${{pid}}"
        }}
        cd ${{INITIAL_DIR}}
        ./{start_background_broker_cmd}
        cd ${{TEST_UNDECLARED_OUTPUTS_DIR}}

        # The test cases will need to be able to load code from the deps
        # directly, so we set ERL_LIBS
        export ERL_LIBS={erl_libs}

        # run the actual tests
        mix test --trace --max-failures 1
    """.format(
        erlang_home=erlang_home,
        elixir_home=elixir_home,
        mix_archives=ctx.attr._mix_archives[MixArchivesProvider].path,
        package_dir=ctx.label.package,
        copy_compiled_deps_command=" && ".join(copy_compiled_deps_commands),
        mix_deps_dir=MIX_DEPS_DIR,
        erl_libs=erl_libs,
        start_background_broker_cmd=ctx.attr._start_background_broker.files.to_list()[0].short_path,
    )

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = script,
    )

    runfiles = ctx.runfiles(ctx.files.srcs)
    runfiles = runfiles.merge(ctx.runfiles(ctx.files.data))
    runfiles = runfiles.merge(
        ctx.runfiles([dep[ErlangLibInfo].lib_dir for dep in ctx.attr.deps]),
    )
    runfiles = runfiles.merge(ctx.attr._start_background_broker[DefaultInfo].default_runfiles)

    return [DefaultInfo(runfiles = runfiles)]

rabbitmqctl_test = rule(
    implementation = _impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".ex", ".exs"]),
        "data": attr.label_list(allow_files = True),
        "deps": attr.label_list(providers = [ErlangLibInfo]),
        "_start_background_broker": attr.label(
            default = Label("//:broker-for-cli-tests"),
        ),
        "_erlang_home": attr.label(default = "//bazel_erlang:erlang_home"),
        "_elixir_home": attr.label(default = "//bazel_erlang:elixir_home"),
        "_mix_archives": attr.label(default = "//bazel_erlang:mix_archives"),
    },
    test = True,
)