defmodule Tymeslot.AppSettingsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  alias Tymeslot.AppSettings

  setup do
    # AppSettings.load!/0 runs on application boot. The tests below toggle
    # Application env directly, so restore it after each one.
    #
    # Snapshot all editable keys so that on_exit is symmetric with the schema:
    # adding a fourth key in future automatically gets cleaned up here.
    originals =
      Map.new(AppSettings.keys(), fn key -> {key, Application.get_env(:tymeslot, key)} end)

    on_exit(fn ->
      # Clear any DB override that a test may have applied for every editable key.
      clear_attrs = Map.new(AppSettings.keys(), fn key -> {key, nil} end)
      {:ok, _settings} = AppSettings.update(clear_attrs)

      # Restore the Application env snapshot captured before the test ran.
      Enum.each(originals, fn
        {key, nil} -> Application.delete_env(:tymeslot, key)
        {key, value} -> Application.put_env(:tymeslot, key, value)
      end)
    end)

    :ok
  end

  describe "update/1 + load!/0" do
    test "applying a DB override flows through Application.get_env" do
      assert {:ok, _updated} = AppSettings.update(%{registration_enabled: false})

      assert Application.get_env(:tymeslot, :registration_enabled) == false
    end

    test "reset/1 restores the captured baseline" do
      Application.put_env(:tymeslot, :registration_enabled, true)
      AppSettings.load!()

      assert {:ok, _updated} = AppSettings.update(%{registration_enabled: false})
      assert Application.get_env(:tymeslot, :registration_enabled) == false

      assert {:ok, _reset} = AppSettings.reset(:registration_enabled)
      assert Application.get_env(:tymeslot, :registration_enabled) == true
    end
  end

  describe "effective_values/0" do
    test "marks a DB-overridden setting as :db" do
      {:ok, _settings} = AppSettings.update(%{registration_enabled: false})

      values = AppSettings.effective_values()

      assert values[:registration_enabled].value == false
      assert values[:registration_enabled].source == :db
    end

    test "marks an unset DB value as :config when an Application env exists" do
      Application.put_env(:tymeslot, :registration_enabled, true)
      AppSettings.load!()

      values = AppSettings.effective_values()

      assert values[:registration_enabled].source == :config
    end
  end
end
