defmodule CredoChecks.HttpClientBoundary do
  @moduledoc """
  Flags outbound HTTP calls that bypass `Tymeslot.Infrastructure.HTTPClient`.

  Every outbound HTTP request must go through the wrapper, reached
  elsewhere as `Config.http_client_module().request(...)` via the
  `Tymeslot.Infrastructure.HTTPClientBehaviour` indirection. The wrapper is
  the one place that enforces a streamed response byte budget
  (`ResponseTooLargeError`), `Tymeslot.Security.SsrfGuard`, connection
  pinning and `ProxyConfig`. Anything calling an HTTP library directly opts
  out of all of it silently: no crash, no warning, just a request that skips
  every one of those guarantees.

  Two shapes are flagged, both under `lib/` only:

    * A call on the single-segment alias `Req` — `Req.get(...)`,
      `Req.post!(...)`, `Req.request(...)`, and so on. Single-segment
      matters: `Req.Test.stub(...)` (legitimate test-stub setup, including
      from `lib/`) is a two-segment alias and is not touched, and struct
      patterns such as `%Req.Response{}` are not call nodes so they never
      match in the first place.
    * A call on `HTTPoison.*`, `Tesla.*`, or the literal atom module
      `:httpc`. All three are banned outright in application code: both
      `:httpoison` and `:tesla` arrive with Wallaby in test (the latter via
      `:web_driver_client`), so they are resolvable in the test build, but
      neither may be called directly, and neither may `:httpc`.

  ## Excluded files

  - `lib/tymeslot/infrastructure/http_client.ex` — the wrapper itself, the
    one legitimate caller of `Req`
  - Files under `lib/mix/tasks/` — dev-only tooling. A `mix release` has no
    `mix` CLI to invoke a `Mix.Task` with, so the code is unreachable in
    production even though it is compiled in
  - Test files
  - An `:allowed` param (list of filename substrings), for any future
    caller with a genuine, reviewed reason to call a library directly:

        {CredoChecks.HttpClientBoundary, [allowed: ["lib/tymeslot/some/exception.ex"]]}

  ## Examples

      # Bad — calling Req directly from a context module
      defmodule MyApp.Integrations.SomeApi do
        def fetch(url), do: Req.get(url)
      end

      # Bad — a banned library, whatever the call
      defmodule MyApp.Integrations.OtherApi do
        def fetch(url), do: HTTPoison.get(url)
      end

      # Good — go through the wrapper
      defmodule MyApp.Integrations.SomeApi do
        alias Tymeslot.Infrastructure.Config

        def fetch(url), do: Config.http_client_module().request(:get, url, nil, [], [])
      end
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    param_defaults: [allowed: []],
    explanations: [
      check: """
      Outbound HTTP requests must go through
      `Tymeslot.Infrastructure.HTTPClient` (reached as
      `Config.http_client_module().request(...)`), which enforces a
      streamed response byte budget, SSRF protection, connection pinning
      and proxy configuration. A direct call to an HTTP library bypasses
      all of it.
      """,
      params: [
        allowed: "List of filename substrings allowed to call an HTTP library directly."
      ]
    ]

  alias Credo.Check.Params
  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @banned_libraries [:HTTPoison, :Tesla]

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    filename = source_file.filename
    allowed = Params.get(params, :allowed, __MODULE__)

    if excluded?(filename, allowed) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  # ---------------------------------------------------------------------------
  # Exclusions
  # ---------------------------------------------------------------------------

  defp excluded?(filename, allowed) do
    not lib_file?(filename) or
      wrapper_file?(filename) or
      mix_task_file?(filename) or
      test_file?(filename) or
      Enum.any?(allowed, &String.contains?(filename, &1))
  end

  defp lib_file?(filename),
    do: String.contains?(filename, "/lib/") or String.starts_with?(filename, "lib/")

  defp wrapper_file?(filename),
    do: String.ends_with?(filename, "/infrastructure/http_client.ex")

  defp mix_task_file?(filename),
    do:
      String.contains?(filename, "/lib/mix/tasks/") or
        String.starts_with?(filename, "lib/mix/tasks/")

  defp test_file?(filename) do
    String.contains?(filename, "/test/") or String.starts_with?(filename, "test/") or
      String.ends_with?(filename, "_test.exs")
  end

  # ---------------------------------------------------------------------------
  # Traversal
  # ---------------------------------------------------------------------------

  # `Req.foo(...)` — single-segment alias only, so `Req.Test.stub(...)`
  # (two segments) is never matched here.
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Req]}, func_name]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when is_list(args) do
    {ast, [build_req_issue(issue_meta, meta[:line], func_name) | issues]}
  end

  # `HTTPoison.foo(...)` / `Tesla.foo(...)` — matched on the alias's first
  # (and, in practice, only) segment.
  defp traverse(
         {{:., _, [{:__aliases__, _, [library | _rest]}, func_name]}, meta, args} = ast,
         issues,
         issue_meta
       )
       when is_list(args) and library in @banned_libraries do
    {ast, [build_banned_library_issue(issue_meta, meta[:line], library, func_name) | issues]}
  end

  # `:httpc.foo(...)` — the module reference is a literal atom, not an alias.
  defp traverse({{:., _, [:httpc, func_name]}, meta, args} = ast, issues, issue_meta)
       when is_list(args) do
    {ast, [build_banned_library_issue(issue_meta, meta[:line], :httpc, func_name) | issues]}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  # ---------------------------------------------------------------------------
  # Issues
  # ---------------------------------------------------------------------------

  defp build_req_issue(issue_meta, line_no, func_name) do
    trigger = "Req.#{func_name}"

    format_issue(issue_meta,
      message:
        "`#{trigger}` bypasses `Tymeslot.Infrastructure.HTTPClient`. Go through " <>
          "`Config.http_client_module().request/1` or call " <>
          "`Tymeslot.Infrastructure.HTTPClient` directly instead of `Req`.",
      line_no: line_no,
      trigger: trigger
    )
  end

  defp build_banned_library_issue(issue_meta, line_no, library, func_name) do
    trigger = "#{library}.#{func_name}"

    format_issue(issue_meta,
      message:
        "`#{library}` is banned outright in application code. The only sanctioned HTTP " <>
          "client is `Req`, reached through `Tymeslot.Infrastructure.HTTPClient`.",
      line_no: line_no,
      trigger: trigger
    )
  end
end
