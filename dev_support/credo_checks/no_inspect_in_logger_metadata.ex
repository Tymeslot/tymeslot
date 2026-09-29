defmodule CredoChecks.NoInspectInLoggerMetadata do
  @moduledoc """
  Flags `inspect/1,2` anywhere in the metadata argument of a Logger call in
  `lib/`.

  `Tymeslot.Infrastructure.Logging.MetadataRedactor` redacts metadata by key,
  walking maps, keyword lists and structs. An inspected value is already a
  string by the time the filter sees it, so every key inside it is invisible:
  a provider's `{:error, %{"access_token" => _}}` logged as
  `reason: inspect(reason)` reaches the log whole. It is also unbounded, so a
  reason carrying a whole HTTP response body becomes a megabyte log line.

  `LogFormat.reason/1` redacts the term by key before inspecting it, scrubs
  the text for credentials and email addresses, and caps its size.

  `Exception.format/2,3` is flagged too: it inspects a non-exception
  reason, and prints the arguments a `FunctionClauseError`'s top frame
  carries, with the same effect. Log `LogFormat.reason/1` of the reason and
  `LogFormat.stacktrace/1` of the stacktrace instead. `Exception.message/1`
  is not flagged: it renders an exception's own message, which is written
  to be read.

  Only `lib/` files are scanned: tests log what they like.

  ## Examples

      # Bad: the redactor sees one opaque string
      Logger.error("Token refresh failed", reason: inspect(reason))
      Logger.error("Token refresh failed", log_context ++ [reason: inspect(reason)])

      # Good
      Logger.error("Token refresh failed", reason: LogFormat.reason(reason))
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Logger metadata must not carry `inspect/1` output: the metadata redactor
      matches sensitive keys, and an inspected term hides every key inside a
      string. Use `Tymeslot.Infrastructure.Logging.LogFormat.reason/1`, which
      redacts the term before rendering it and bounds its size.

      Bad:
          Logger.error("Sync failed", reason: inspect(reason))

      Good:
          Logger.error("Sync failed", reason: LogFormat.reason(reason))
      """
    ]

  alias Credo.IssueMeta

  @logger_levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]
  @excluded_paths ["/test/", "/migrations/", "/deps/"]

  @doc false
  @impl Credo.Check
  @spec run(Credo.SourceFile.t(), keyword()) :: list()
  def run(%Credo.SourceFile{} = source_file, params) do
    if excluded?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      Credo.Code.prewalk(source_file, &traverse(&1, &2, issue_meta))
    end
  end

  defp excluded?(filename) do
    not lib_file?(filename) or Enum.any?(@excluded_paths, &String.contains?(filename, &1))
  end

  defp lib_file?(filename) do
    String.contains?(filename, "/lib/") or String.starts_with?(filename, "lib/")
  end

  # Logger.level(message, metadata)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Logger]}, level]}, _meta, [_message, metadata]} = ast,
         issues,
         issue_meta
       )
       when level in @logger_levels do
    {ast, inspect_issues(metadata, issue_meta) ++ issues}
  end

  # Logger.log(level, message, metadata)
  defp traverse(
         {{:., _, [{:__aliases__, _, [:Logger]}, :log]}, _meta, [_level, _message, metadata]} =
           ast,
         issues,
         issue_meta
       ) do
    {ast, inspect_issues(metadata, issue_meta) ++ issues}
  end

  defp traverse(ast, issues, _issue_meta), do: {ast, issues}

  defp inspect_issues(metadata, issue_meta) do
    {_ast, found} = Macro.prewalk(metadata, [], &collect_inspect/2)

    found
    |> Enum.reverse()
    |> Enum.map(fn {trigger, line} ->
      format_issue(issue_meta, message: message(trigger), line_no: line, trigger: trigger)
    end)
  end

  defp message("inspect"),
    do:
      "Render Logger metadata with LogFormat.reason/1, not inspect: the metadata " <>
        "redactor cannot see the keys inside an inspected string."

  defp message("Exception.format"),
    do:
      "Log LogFormat.reason/1 of the reason and LogFormat.stacktrace/1 of the " <>
        "stacktrace, not Exception.format: it inspects the reason and the arguments " <>
        "in the stacktrace, out of the metadata redactor's reach."

  # `&inspect/1`, `&Kernel.inspect/2`: recorded once and not descended into,
  # so the bare `inspect` inside the capture is not counted a second time.
  defp collect_inspect({:&, meta, [{:/, _, [fun, _arity]}]} = ast, lines) do
    if inspect_ref?(fun), do: {:captured, [{"inspect", meta[:line]} | lines]}, else: {ast, lines}
  end

  defp collect_inspect({:inspect, meta, args} = ast, lines) when is_list(args),
    do: {ast, [{"inspect", meta[:line]} | lines]}

  defp collect_inspect(
         {{:., _, [{:__aliases__, _, [:Kernel]}, :inspect]}, meta, args} = ast,
         lines
       )
       when is_list(args),
       do: {ast, [{"inspect", meta[:line]} | lines]}

  defp collect_inspect(
         {{:., _, [{:__aliases__, _, [:Exception]}, :format]}, meta, args} = ast,
         lines
       )
       when is_list(args),
       do: {ast, [{"Exception.format", meta[:line]} | lines]}

  defp collect_inspect(ast, lines), do: {ast, lines}

  defp inspect_ref?({:inspect, _, context}) when is_atom(context), do: true
  defp inspect_ref?({{:., _, [{:__aliases__, _, [:Kernel]}, :inspect]}, _, []}), do: true
  defp inspect_ref?(_fun), do: false
end
