"""Scalafix integration.

Everything is driven by the `scalafix` macro, which defines two runnable targets:

    bazel run //:scalafix                       # apply the rules to all Scala files changed compared to origin/master
    bazel run //:scalafix.check                 # same but only check (non zero exit code on violations)
    bazel run //:scalafix -- --diff-base main   # use another base
    bazel run //:scalafix -- --all              # do not restrict to changed files
    bazel run //:scalafix -- --files foo.scala  # only specific files
    bazel run //:scalafix -- --target //foo/...  # only build/consider the given targets instead of the configured ones

Any other argument is passed on to the Scalafix CLI.

which is the Bazel equivalent of the sbt invocation

    scalafix --diff-base origin/master RestrictedImports SingleLetterIdentifiers UnorderedIteration

How it works:
  1. The Scala toolchain (//scala_toolchain) makes every scala target bundle its SemanticDB into its jar.
  2. `scalafix_aspect` writes a small manifest per Scala target: its sources, scalac options and classpath.
  3. The runner script builds all manifests with the aspect, selects the ones with relevant sources and
     calls the Scalafix CLI once per target with the sources, the classpath and the rules classpath.
"""

load("@rules_java//java/common:java_info.bzl", "JavaInfo")

# Must be kept in sync with the Scala version in //scala_toolchain (see check_version.bzl there).
SCALA_VERSION = "3.8.3"

MANIFEST_OUTPUT_GROUP = "scalafix_manifest"

# Line based format to be consumable from plain bash:
#   N<label>   the target label
#   S<path>    a Scala source file of the main repository (workspace relative)
#   O<option>  one scalac option
#   J<path>    a classpath entry (execroot relative). The first ones are the jars of the target itself.
def _scalafix_aspect_impl(target, ctx):
    empty = [OutputGroupInfo(**{MANIFEST_OUTPUT_GROUP: depset()})]

    # We only care about our own sources and never about dependencies from other modules.
    if target.label.workspace_name != "":
        return empty

    # Opt out, e.g. for test fixtures that contain violations on purpose.
    if "no-scalafix" in ctx.rule.attr.tags:
        return empty
    if JavaInfo not in target or not hasattr(ctx.rule.files, "srcs"):
        return empty
    srcs = [f for f in ctx.rule.files.srcs if f.extension == "scala" and f.is_source]
    if not srcs:
        return empty

    java_info = target[JavaInfo]
    own_jars = [o.class_jar for o in java_info.java_outputs if o.class_jar]
    jars = depset(own_jars, transitive = [java_info.transitive_compile_time_jars])

    manifest = ctx.actions.declare_file(target.label.name + ".scalafix_manifest")
    args = ctx.actions.args()
    args.set_param_file_format("multiline")
    args.add("N" + str(target.label))
    args.add_all(srcs, format_each = "S%s")
    args.add_all(getattr(ctx.rule.attr, "scalacopts", []), format_each = "O%s")
    args.add_all(jars, format_each = "J%s")
    ctx.actions.write(manifest, args)

    # The jars are part of the output group so that they get built together with the manifest.
    return [OutputGroupInfo(**{MANIFEST_OUTPUT_GROUP: depset([manifest], transitive = [jars])})]

scalafix_aspect = aspect(
    implementation = _scalafix_aspect_impl,
    doc = "Collects sources and classpath of Scala targets for the Scalafix runner.",
)

def _scalafix_runner_impl(ctx):
    rules_info = ctx.attr.rules_lib[JavaInfo]
    tool_classpath = rules_info.transitive_runtime_jars

    def rf_path(f):
        # Path of a file inside the runfiles tree relative to the runfiles root.
        if f.short_path.startswith("../"):
            return f.short_path[3:]
        return ctx.workspace_name + "/" + f.short_path

    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    ctx.actions.expand_template(
        template = ctx.file._template,
        output = script,
        is_executable = True,
        substitutions = {
            "%ASPECT%": "@bazel_tooling//scalafix:defs.bzl%scalafix_aspect",
            "%CHECK%": "1" if ctx.attr.check else "0",
            "%CLI%": rf_path(ctx.executable._cli),
            "%DIFF_BASE%": ctx.attr.diff_base,
            "%MANIFEST_OUTPUT_GROUP%": MANIFEST_OUTPUT_GROUP,
            "%RULES%": " ".join([_shell_quote(r) for r in ctx.attr.rules]),
            "%SCALA_VERSION%": ctx.attr.scala_version,
            "%TARGETS%": " ".join([_shell_quote(t) for t in ctx.attr.targets]),
            "%TOOL_CLASSPATH%": ":".join([rf_path(f) for f in tool_classpath.to_list()]),
        },
    )

    runfiles = ctx.runfiles(files = tool_classpath.to_list()).merge(ctx.attr._cli[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

def _shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"

_scalafix_runner = rule(
    implementation = _scalafix_runner_impl,
    executable = True,
    attrs = {
        "check": attr.bool(default = False),
        "diff_base": attr.string(),
        "rules": attr.string_list(mandatory = True),
        "rules_lib": attr.label(providers = [JavaInfo], mandatory = True),
        "scala_version": attr.string(),
        "targets": attr.string_list(),
        "_cli": attr.label(
            default = Label("//scalafix:scalafix_cli"),
            executable = True,
            cfg = "exec",
        ),
        "_template": attr.label(
            default = Label("//scalafix:scalafix_runner.sh.tpl"),
            allow_single_file = True,
        ),
    },
)

def scalafix(
        name,
        rules_lib,
        rules,
        targets = ["//..."],
        diff_base = "origin/master",
        scala_version = SCALA_VERSION,
        **kwargs):
    """Defines the runnable targets `<name>` (apply) and `<name>.check` (verify only).

    Args:
      name: Name of the apply target.
      rules_lib: A scala_library with the Scalafix rules (META-INF/services/scalafix.v1.Rule registered).
      rules: Names of the rules to run.
      targets: Bazel target patterns whose Scala sources may be checked.
      diff_base: Git ref. Only files changed compared to it are checked. Can be overridden with --diff-base
        or disabled with --all.
      scala_version: Scala version the sources are written in.
      **kwargs: Passed to the generated targets, e.g. visibility.
    """
    for target_name, check in [(name, False), (name + ".check", True)]:
        _scalafix_runner(
            name = target_name,
            check = check,
            diff_base = diff_base,
            rules = rules,
            rules_lib = rules_lib,
            scala_version = scala_version,
            targets = targets,
            **kwargs
        )

def _testkit_properties_impl(ctx):
    """Generates the scalafix-testkit.properties resource for the Scalafix testkit (AbstractSemanticRuleSuite).

    All paths are relative to the working directory of the test which is the `<workspace>` directory inside of
    the runfiles tree. Files of the test input target and its sources must be `data` of the test.
    """
    java_info = ctx.attr.input[JavaInfo]

    def rf_relative(f):
        if f.short_path.startswith("../"):
            return f.short_path
        return "../" + ctx.workspace_name + "/" + f.short_path

    classpath = [rf_relative(f) for f in java_info.transitive_runtime_jars.to_list()]
    props = {
        "inputClasspath": ":".join(classpath),
        "inputSourceDirectories": ":".join(ctx.attr.input_source_dirs),
        "outputSourceDirectories": "",
        "scalaVersion": ctx.attr.scala_version,
        "scalacOptions": "|".join(ctx.attr.scalac_options),
        # Working directory of the test, i.e. the workspace root. SemanticDB URIs are relative to it.
        "sourceroot": ".",
    }
    out = ctx.actions.declare_file(ctx.label.name + "/scalafix-testkit.properties")
    ctx.actions.write(out, "".join([k + "=" + v + "\n" for k, v in props.items()]))
    return [DefaultInfo(files = depset([out]))]

scalafix_testkit_properties = rule(
    implementation = _testkit_properties_impl,
    doc = "Generates scalafix-testkit.properties. Use it as `resources` of the scala_test running the testkit suite " +
          "together with `resource_strip_prefix = \"<package>/<name>\"` because the testkit expects the file at " +
          "the root of the classpath.",
    attrs = {
        "input": attr.label(
            providers = [JavaInfo],
            mandatory = True,
            doc = "scala_library with the test input files. Compiled with SemanticDB by our toolchain.",
        ),
        "input_source_dirs": attr.string_list(
            mandatory = True,
            doc = "Workspace relative directories with the sources of `input`.",
        ),
        "scala_version": attr.string(default = SCALA_VERSION),
        "scalac_options": attr.string_list(),
    },
)
