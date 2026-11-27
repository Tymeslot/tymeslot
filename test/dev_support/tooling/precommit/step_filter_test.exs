defmodule Tymeslot.Precommit.StepFilterTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.StepFilter

  @steps [
    {"format", ~w[format --check-formatted], :dev},
    {"compile", ~w[compile --warnings-as-errors], :dev},
    {"credo", ~w[credo --strict], :dev},
    {"css tokens", ~w[css.check_tokens], :dev},
    {"test", ~w[test], :test},
    {"dialyzer", ~w[dialyzer.incremental --list-unused-filters], :dev}
  ]

  defp filter(argv) do
    {opts, []} = OptionParser.parse!(argv, strict: StepFilter.switches())
    StepFilter.filter(@steps, opts)
  end

  defp names(steps), do: Enum.map(steps, &elem(&1, 0))

  test "without either flag every step runs and none is reported" do
    assert filter([]) == {@steps, []}
  end

  test "--only keeps the named steps in gate order and reports the rest" do
    {kept, left_out} = filter(["--only", "dialyzer,credo"])

    assert names(kept) == ["credo", "dialyzer"]

    assert left_out == [
             {"format", "left out by --only"},
             {"compile", "left out by --only"},
             {"css tokens", "left out by --only"},
             {"test", "left out by --only"}
           ]
  end

  test "--skip drops the named steps and keeps the rest" do
    {kept, left_out} = filter(["--skip", "test", "--skip", "dialyzer"])

    assert names(kept) == ["format", "compile", "credo", "css tokens"]
    assert left_out == [{"test", "left out by --skip"}, {"dialyzer", "left out by --skip"}]
  end

  test "names with spaces match, and blanks around commas are ignored" do
    {kept, _left_out} = filter(["--only", " css tokens , ,credo"])

    assert names(kept) == ["credo", "css tokens"]
  end

  test "a name the gate does not have fails the run, naming the valid ones" do
    error = assert_raise Mix.Error, fn -> filter(["--skip", "tests,credo"]) end

    assert error.message =~ ~s(no precommit step named "tests";)
    assert error.message =~ "format, compile, credo, css tokens, test, dialyzer"
  end

  test "--only and --skip together fail the run" do
    assert_raise Mix.Error, "--only and --skip cannot be combined", fn ->
      filter(["--only", "credo", "--skip", "test"])
    end
  end
end
