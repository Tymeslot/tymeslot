defmodule Tymeslot.Utils.SanitizeMergeTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Utils.SanitizeMerge

  describe "merge/2 — non-drop values" do
    test "sanitised string wins over params string" do
      params = %{"name" => "raw"}
      sanitized = %{"name" => "clean"}

      assert SanitizeMerge.merge(params, sanitized) == %{"name" => "clean"}
    end

    test "stripped-to-empty string still overwrites populated params" do
      # Security-critical: HTML-stripping sanitisers return "" for inputs
      # that contained only markup. That empty string must overwrite the raw
      # user-provided value — otherwise the unsanitised payload leaks
      # through.
      params = %{"description" => "<script></script>"}
      sanitized = %{"description" => ""}

      assert SanitizeMerge.merge(params, sanitized) == %{"description" => ""}
    end

    test "empty string sanitised value also overwrites already-empty params" do
      params = %{"description" => ""}
      sanitized = %{"description" => ""}

      assert SanitizeMerge.merge(params, sanitized) == %{"description" => ""}
    end

    test "integer sanitised value overwrites string params" do
      params = %{"calendar_integration_id" => "5"}
      sanitized = %{"calendar_integration_id" => 5}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_integration_id" => 5}
    end

    test "sanitised keys missing from params are added" do
      params = %{"name" => "Cal"}
      sanitized = %{"url" => "https://cal.example.com"}

      assert SanitizeMerge.merge(params, sanitized) == %{
               "name" => "Cal",
               "url" => "https://cal.example.com"
             }
    end

    test "params keys not referenced by sanitizer are preserved" do
      params = %{"name" => "Cal", "extra" => "kept"}
      sanitized = %{"name" => "Clean"}

      assert SanitizeMerge.merge(params, sanitized) == %{"name" => "Clean", "extra" => "kept"}
    end
  end

  describe "merge/2 — nil drop signal" do
    test "nil sanitised value does not overwrite populated params" do
      # Optional-field validators return `{:ok, nil}` when the field was
      # never provided. Merging that nil over a populated params entry
      # would silently drop the user's selection.
      params = %{"calendar_integration_id" => 5}
      sanitized = %{"calendar_integration_id" => nil}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_integration_id" => 5}
    end

    test "nil sanitised value falls through when params was also nil" do
      params = %{"calendar_integration_id" => nil}
      sanitized = %{"calendar_integration_id" => nil}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_integration_id" => nil}
    end

    test "nil sanitised value falls through when key missing from params" do
      # When params had no value at all, the sanitiser's nil is the
      # authoritative "no value" — write it through so the result shape
      # matches `Map.merge/2`.
      params = %{}
      sanitized = %{"calendar_integration_id" => nil}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_integration_id" => nil}
    end
  end

  describe "merge/2 — empty list drop signal" do
    test "empty list does not overwrite populated non-list params value" do
      # Selection merge emits `calendar_paths: []` when zero items are
      # selected. Merging that over a user-provided path string would
      # silently erase their input.
      params = %{"calendar_paths" => "/cal1,/cal2"}
      sanitized = %{"calendar_paths" => []}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_paths" => "/cal1,/cal2"}
    end

    test "empty list does not overwrite populated list params value" do
      params = %{"calendar_list" => [%{"path" => "/cal1"}]}
      sanitized = %{"calendar_list" => []}

      assert SanitizeMerge.merge(params, sanitized) == %{
               "calendar_list" => [%{"path" => "/cal1"}]
             }
    end

    test "empty list is written through when params was also empty list" do
      params = %{"calendar_list" => []}
      sanitized = %{"calendar_list" => []}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_list" => []}
    end

    test "empty list is written through when params was nil" do
      params = %{"calendar_list" => nil}
      sanitized = %{"calendar_list" => []}

      assert SanitizeMerge.merge(params, sanitized) == %{"calendar_list" => []}
    end

    test "non-empty list always overwrites" do
      params = %{"calendar_list" => [%{"path" => "/raw"}]}
      sanitized = %{"calendar_list" => [%{"path" => "/clean"}]}

      assert SanitizeMerge.merge(params, sanitized) == %{
               "calendar_list" => [%{"path" => "/clean"}]
             }
    end
  end

  describe "merge/2 — atom keys" do
    test "works uniformly with atom keys" do
      params = %{name: "raw", optional_id: 5}
      sanitized = %{name: "clean", optional_id: nil}

      assert SanitizeMerge.merge(params, sanitized) == %{name: "clean", optional_id: 5}
    end
  end
end
