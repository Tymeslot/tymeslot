defmodule Tymeslot.Precommit.AffectedTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support

  alias Tymeslot.Precommit.Affected

  # The gate's real shape, so a rule keyed to a command the gate no longer
  # runs would show up as a step that is never dropped.
  @steps [
    {"format", ~w[format --check-formatted], :dev},
    {"deps.unlock", ~w[deps.unlock --check-unused], :dev},
    {"compile", ~w[compile --warnings-as-errors], :dev},
    {"compile (test)", ~w[compile --warnings-as-errors], :test},
    {"gettext", ~w[gettext.check], :dev},
    {"credo", ~w[credo --strict], :dev},
    {"sobelow", ~w[sobelow], :dev},
    {"deps.audit", ~w[deps.audit], :dev},
    {"migrations", ~w[excellent_migrations.check_safety], :dev},
    {"workflows", ~w[actionlint], :dev},
    {"xref", ~w[xref graph --label compile-connected --fail-above 27], :dev},
    {"test", ~w[test], :test},
    {"dialyzer", ~w[dialyzer.incremental --list-unused-filters], :dev}
  ]

  @always_with_suite [
    "format",
    "compile",
    "compile (test)",
    "gettext",
    "credo",
    "xref",
    "test",
    "dialyzer"
  ]

  # Large enough that a one-domain selection stays under the threshold past
  # which `Selection` takes the full suite instead.
  defp index do
    tags = %{
      "test/tymeslot/auth/session_test.exs" => MapSet.new([:auth]),
      "test/tymeslot/payments/stripe_test.exs" => MapSet.new([:payments]),
      "test/tymeslot/payments/refund_test.exs" => MapSet.new([:payments]),
      "test/tymeslot/analytics/report_test.exs" => MapSet.new([:analytics]),
      "test/tymeslot/analytics/export_test.exs" => MapSet.new([:analytics]),
      "test/tymeslot/analytics/funnel_test.exs" => MapSet.new([:analytics])
    }

    %{
      test_files: tags |> Map.keys() |> MapSet.new(),
      tags: tags,
      domain_tags: MapSet.new([:auth, :payments, :analytics])
    }
  end

  defp names(%{steps: steps}), do: Enum.map(steps, fn {name, _args, _env} -> name end)

  defp test_args(%{steps: steps}) do
    Enum.find_value(steps, fn
      {"test", args, :test} -> args
      _step -> nil
    end)
  end

  describe "select/4" do
    test "a lib change runs the static steps and only the tests it affects" do
      narrowed = Affected.select(@steps, ["lib/tymeslot/payments/stripe.ex"], index())

      assert names(narrowed) == @always_with_suite

      assert test_args(narrowed) == [
               "test",
               "test/tymeslot/payments/refund_test.exs",
               "test/tymeslot/payments/stripe_test.exs"
             ]
    end

    test "every dropped step is reported with its reason" do
      narrowed = Affected.select(@steps, ["lib/tymeslot/payments/stripe.ex"], index())

      assert narrowed.skipped == [
               {"deps.unlock", "mix.exs and mix.lock unchanged"},
               {"sobelow", "no web, config, auth or upload code changed"},
               {"deps.audit", "mix.exs and mix.lock unchanged"},
               {"migrations", "no migration changed"},
               {"workflows", "no workflow changed"}
             ]
    end

    test "each conditional step runs when the diff touches its input" do
      cases = [
        {"mix.lock", ["deps.unlock", "deps.audit"]},
        {"lib/tymeslot_web/live/dashboard_live.ex", ["sobelow"]},
        {"lib/tymeslot/auth/session.ex", ["sobelow"]},
        {"config/runtime.exs", ["sobelow"]},
        {"priv/repo/migrations/20260101000000_add_x.exs", ["migrations"]},
        {".github/workflows/verify.yml", ["workflows"]}
      ]

      for {path, expected} <- cases do
        ran = names(Affected.select(@steps, [path], index()))
        assert Enum.filter(ran, &(&1 in expected)) == expected, "#{path} ran #{inspect(ran)}"
      end
    end

    test "a docs-only diff runs nothing" do
      narrowed = Affected.select(@steps, ["README.md", "assets/css/app.css"], index())

      assert narrowed.steps == []
      assert length(narrowed.skipped) == length(@steps)
    end

    test "a workflow-only diff runs actionlint and nothing else" do
      assert names(Affected.select(@steps, [".gitea/workflows/verify.yml"], index())) == [
               "workflows"
             ]
    end

    test "a change that widens takes the full suite" do
      narrowed = Affected.select(@steps, ["test/support/factory.ex"], index())

      assert test_args(narrowed) == ["test"]
    end

    test "a migration takes the full suite with the migrations tag included" do
      narrowed =
        Affected.select(@steps, ["priv/repo/migrations/20260101000000_add_x.exs"], index())

      assert test_args(narrowed) == ["test", "--include", "migrations"]
    end

    test "an upstream code change runs the static steps and the full suite" do
      narrowed =
        Affected.select(@steps, [], index(), upstream: ["lib/tymeslot/bookings/reschedule.ex"])

      assert narrowed.suite == :upstream
      assert names(narrowed) == @always_with_suite
      assert test_args(narrowed) == ["test"]
    end

    test "an upstream docs change is ignored" do
      narrowed = Affected.select(@steps, [], index(), upstream: ["CHANGELOG.md"])

      assert narrowed.steps == []
    end

    test "upstream changes never trigger this repository's conditional steps" do
      narrowed = Affected.select(@steps, [], index(), upstream: ["mix.lock"])

      refute "deps.unlock" in names(narrowed)
      assert "test" in names(narrowed)
    end
  end
end
