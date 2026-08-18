defmodule Tymeslot.Integrations.Video.SelectionTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Video.Selection

  # `recommend_provider/1` currently ignores its requirements and always returns
  # the registry's default provider. These tests pin that documented contract:
  # they will fail loudly if requirement-aware selection is ever implemented
  # without updating the expectations here.
  describe "recommend_provider/1" do
    test "returns recommended provider for default requirements" do
      assert Selection.recommend_provider() == :mirotalk
    end

    test "returns recommended provider for small meeting" do
      requirements = %{
        participant_count: 5,
        recording_required: false
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns recommended provider for large meeting" do
      requirements = %{
        participant_count: 50,
        recording_required: true
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns recommended provider for recording required" do
      requirements = %{
        recording_required: true
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end

    test "returns recommended provider for screen sharing required" do
      requirements = %{
        screen_sharing_required: true
      }

      assert Selection.recommend_provider(requirements) == :mirotalk
    end
  end
end
