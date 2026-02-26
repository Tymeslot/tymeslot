defmodule TymeslotWeb.Themes.Core.ValidatorTest do
  use ExUnit.Case, async: false
  @moduletag :utils

  alias Tymeslot.Themes.Theme
  alias TymeslotWeb.Themes.Core.Validator
  import ExUnit.CaptureLog

  setup_all do
    # Ensure info logs are captured
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  describe "validate_all_themes/0" do
    test "returns :ok when all themes are valid" do
      assert capture_log(fn ->
               assert :ok = Validator.validate_all_themes()
             end) =~ "All themes validated successfully"
    end

    test "returns error when theme validation fails" do
      # Mock Theme.validate_all_themes/0
      :meck.new(Theme, [:passthrough])

      :meck.expect(
        Theme,
        :validate_all_themes,
        0,
        {:error, [{"broken", {:error, "Broken theme"}}]}
      )

      try do
        assert capture_log(fn ->
                 assert {:error, [{"broken", {:error, "Broken theme"}}]} =
                          Validator.validate_all_themes()
               end) =~ "Theme validation failure"
      after
        :meck.unload(Theme)
      end
    end
  end

  describe "validate_theme_independence/0" do
    test "returns :ok when all themes implement required behavior" do
      assert capture_log(fn ->
               assert :ok = Validator.validate_theme_independence()
             end) =~ "All themes are properly independent"
    end

    test "returns error when a theme is missing behavior functions" do
      defmodule IncompleteTheme do
        # Missing some required functions
        @spec theme_config() :: map()
        def theme_config, do: %{name: "Incomplete"}
      end

      :meck.new(Theme, [:passthrough])
      :meck.expect(Theme, :all_themes, 0, %{"incomplete" => %{id: "incomplete"}})
      :meck.expect(Theme, :get_theme_module, 1, IncompleteTheme)

      try do
        assert capture_log(fn ->
                 assert {:error, [{"incomplete", {:error, reason}}]} =
                          Validator.validate_theme_independence()

                 assert reason =~ "Missing behavior functions"
               end) =~ "Theme independence failure"
      after
        :meck.unload(Theme)
      end
    end
  end

  describe "validate_theme_components/0" do
    test "returns :ok when all theme components load and implement LiveComponent" do
      assert capture_log(fn ->
               assert :ok = Validator.validate_theme_components()
             end) =~ "All theme components load successfully"
    end

    test "returns error when a component does not implement LiveComponent behavior" do
      defmodule InvalidComponent do
        # Missing update/2
        @spec some_function() :: :ok
        def some_function, do: :ok
      end

      :meck.new(Theme, [:passthrough])
      :meck.expect(Theme, :all_themes, 0, %{"test" => %{id: "test"}})
      :meck.expect(Theme, :get_components, 1, %{invalid: InvalidComponent})

      try do
        assert capture_log(fn ->
                 assert {:error, [{{"test", :invalid}, {:error, reason}}]} =
                          Validator.validate_theme_components()

                 assert reason == "Component does not implement LiveComponent behavior"
               end) =~
                 "Theme component failure"
      after
        :meck.unload(Theme)
      end
    end

    test "returns error when component module cannot be loaded" do
      :meck.new(Theme, [:passthrough])
      :meck.expect(Theme, :all_themes, 0, %{"test" => %{id: "test"}})
      # Use a non-existent module
      :meck.expect(Theme, :get_components, 1, %{missing: NonExistentComponent})

      try do
        assert capture_log(fn ->
                 assert {:error, [{{"test", :missing}, {:error, reason}}]} =
                          Validator.validate_theme_components()

                 assert reason =~ "Failed to load component module"
               end) =~ "Theme component failure"
      after
        :meck.unload(Theme)
      end
    end
  end

  describe "independence tests edge cases" do
    test "returns error when theme module is nil" do
      :meck.new(Theme, [:passthrough])
      :meck.expect(Theme, :all_themes, 0, %{"missing" => %{id: "missing"}})
      :meck.expect(Theme, :get_theme_module, 1, nil)

      try do
        assert capture_log(fn ->
                 assert {:error, [{"missing", {:error, "Theme module not found"}}]} =
                          Validator.validate_theme_independence()
               end) =~ "Theme independence failure"
      after
        :meck.unload(Theme)
      end
    end

    test "returns error when exception occurs during independence test" do
      :meck.new(Theme, [:passthrough])
      :meck.expect(Theme, :all_themes, 0, %{"error" => %{id: "error"}})
      :meck.expect(Theme, :get_theme_module, 1, fn _theme_id -> raise "Boom" end)

      try do
        assert capture_log(fn ->
                 assert {:error, [{"error", {:error, reason}}]} =
                          Validator.validate_theme_independence()

                 assert reason =~ "Exception during theme independence test"
               end) =~ "Theme independence failure"
      after
        :meck.unload(Theme)
      end
    end
  end

  describe "run_full_validation/0" do
    test "returns :ok when all validations pass" do
      assert capture_log(fn ->
               assert :ok = Validator.run_full_validation()
             end) =~ "All theme system validations passed"
    end

    test "returns error when any validation fails" do
      :meck.new(Theme, [:passthrough])
      :meck.expect(Theme, :validate_all_themes, 0, {:error, [{"broken", {:error, "fail"}}]})

      try do
        assert capture_log(fn ->
                 assert {:error, [{"Theme Registration", _error_reason}]} =
                          Validator.run_full_validation()
               end) =~ "Theme system validation failed"
      after
        :meck.unload(Theme)
      end
    end
  end
end
