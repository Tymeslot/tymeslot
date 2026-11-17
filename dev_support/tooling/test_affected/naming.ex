defmodule Tymeslot.TestAffected.Naming do
  @moduledoc """
  Finds who names a file or a module, for `Tymeslot.TestAffected.Selection`.

  A module under `test/support/` reaches the tests that name it, directly or
  through other support modules naming it, so a change selects those tests.
  It widens instead when the suite's configuration (`config/`,
  `test/test_helper.exs`) or application code names it, since then it runs
  wherever that configuration does (a Mox mock or a fixture theme registered
  in `config/test.exs`), and when it defines no module. The shared foundations
  (`DataCase`, `ConnCase`, the factories) are named by most of the suite, so
  they reach the full suite through the size threshold rather than a list.

  Module names are matched as text, after a multi-alias such as
  `alias Tymeslot.{Auth, Bookings}` is expanded to the names it brings in, so
  a module is found however it is aliased. A module reached only through a
  name built at runtime is missed; that is the price of not compiling the
  suite to find out, and the push-time gate is the backstop.
  """

  alias Tymeslot.TestAffected.Selection

  @defmodule_re ~r/defmodule\s+([A-Z][\w.]*)/
  @support_prefix "test/support/"
  @source_prefixes ~w[lib/ dev_support/]

  # A parent directory shorter than this is too general to count as naming a
  # file: `priv` would match nearly every module that reads anything.
  @min_named_segments 2

  defp contains?(source, pattern), do: :binary.match(source, pattern) != :nomatch

  @doc """
  The files naming `path`, or a parent directory of at least two segments,
  split into test files and the rest.
  """
  @spec named_by(String.t(), Selection.index()) :: {[String.t()], [String.t()]}
  def named_by(path, index) do
    pattern = path |> needles() |> :binary.compile_pattern()

    index.sources
    |> Enum.filter(fn {file, source} -> file != path and contains?(source, pattern) end)
    |> Enum.map(fn {file, _source} -> file end)
    |> Enum.sort()
    |> Enum.split_with(&MapSet.member?(index.test_files, &1))
  end

  # The path itself, and each parent directory long enough to be specific.
  defp needles(path) do
    segments = Path.split(path)

    (length(segments) - 1)..@min_named_segments//-1
    |> Enum.map(&(segments |> Enum.take(&1) |> Path.join()))
    |> then(&[path | &1])
  end

  @doc """
  The test files naming one of the modules `path` defines, and the source
  files under `lib/` or `dev_support/` (its callers) that do. A colocated
  template resolves through its module.
  """
  @spec code_naming(String.t(), Selection.index()) :: {[String.t()], [String.t()]}
  def code_naming(path, index) do
    source = String.replace_suffix(path, ".html.heex", ".ex")

    case module_names(source, index) do
      [] ->
        {[], []}

      names ->
        {tests, others} = named_by_any(names, source, index)
        {tests, Enum.filter(others, &String.starts_with?(&1, @source_prefixes))}
    end
  end

  defp module_names(file, index) do
    @defmodule_re |> Regex.scan(Map.get(index.sources, file, "")) |> Enum.map(&List.last/1)
  end

  # Every file other than `except` whose source contains one of `names`, split
  # into test files and the rest.
  defp named_by_any(names, except, index) do
    pattern = :binary.compile_pattern(names)

    index.sources
    |> Enum.filter(fn {file, source} -> file != except and contains?(source, pattern) end)
    |> Enum.map(fn {file, _source} -> file end)
    |> Enum.sort()
    |> Enum.split_with(&MapSet.member?(index.test_files, &1))
  end

  @doc """
  The test files a test-support file reaches, through any chain of support
  modules naming each other, or `{:widen, why}` when the configuration or
  application code names it, or it defines no module.
  """
  @spec support_users(String.t(), Selection.index()) :: {:ok, [String.t()]} | {:widen, String.t()}
  def support_users(path, index), do: walk_support([path], MapSet.new([path]), [], index)

  defp walk_support([], _seen, tests, _index), do: {:ok, Enum.uniq(tests)}

  defp walk_support([file | rest], seen, tests, index) do
    with {:ok, names} <- support_module_names(file, index),
         :ok <- not_configured(file, names, index),
         {found, others} = named_by_any(names, file, index),
         {support, code} = Enum.split_with(others, &String.starts_with?(&1, @support_prefix)),
         :ok <- not_named_by_code(file, code) do
      new = Enum.reject(support, &MapSet.member?(seen, &1))
      walk_support(rest ++ new, Enum.into(new, seen), tests ++ found, index)
    end
  end

  defp support_module_names(file, index) do
    case module_names(file, index) do
      [] -> {:widen, "#{file} defines no module"}
      names -> {:ok, names}
    end
  end

  defp not_configured(file, names, index) do
    pattern = :binary.compile_pattern(names)

    case Enum.find(Map.get(index, :config, %{}), fn {_path, s} -> contains?(s, pattern) end) do
      nil -> :ok
      {config, _source} -> {:widen, "#{file} is named by #{config}, so it runs suite-wide"}
    end
  end

  defp not_named_by_code(_file, []), do: :ok
  defp not_named_by_code(file, [code | _rest]), do: {:widen, "#{file} is named by #{code}"}
end
