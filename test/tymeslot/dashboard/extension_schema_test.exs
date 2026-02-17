defmodule Tymeslot.Dashboard.ExtensionSchemaTest do
  use ExUnit.Case, async: true

  alias Tymeslot.Dashboard.ExtensionSchema

  describe "validate/1" do
    test "accepts a valid extension" do
      extension = %{
        id: :subscription,
        label: "Subscription",
        icon: :credit_card,
        path: "/dashboard/subscription",
        action: :subscription
      }

      assert :ok = ExtensionSchema.validate(extension)
    end

    test "rejects extension missing required fields" do
      extension = %{id: :test}

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert "Missing required field: label" in errors
      assert "Missing required field: icon" in errors
      assert "Missing required field: path" in errors
      assert "Missing required field: action" in errors
    end

    test "rejects extension with invalid id type" do
      extension = %{
        id: "not_an_atom",
        label: "Test",
        icon: :home,
        path: "/test",
        action: :test
      }

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert Enum.any?(errors, &String.contains?(&1, "Field :id must be a atom"))
    end

    test "rejects extension with invalid label type" do
      extension = %{
        id: :test,
        label: 123,
        icon: :home,
        path: "/test",
        action: :test
      }

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert Enum.any?(errors, &String.contains?(&1, "Field :label must be a string"))
    end

    test "rejects extension with invalid icon" do
      extension = %{
        id: :test,
        label: "Test",
        icon: :invalid_icon,
        path: "/test",
        action: :test
      }

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert Enum.any?(errors, &String.contains?(&1, "Invalid icon :invalid_icon"))
    end

    test "accepts all available icons" do
      for icon <- ExtensionSchema.available_icons() do
        extension = %{
          id: :test,
          label: "Test",
          icon: icon,
          path: "/test",
          action: :test
        }

        assert :ok = ExtensionSchema.validate(extension)
      end
    end

    test "rejects path not starting with /" do
      extension = %{
        id: :test,
        label: "Test",
        icon: :home,
        path: "dashboard/test",
        action: :test
      }

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert Enum.any?(errors, &String.contains?(&1, "Path must start with '/'"))
    end

    test "accepts path starting with /" do
      extension = %{
        id: :test,
        label: "Test",
        icon: :home,
        path: "/dashboard/test",
        action: :test
      }

      assert :ok = ExtensionSchema.validate(extension)
    end

    test "rejects extension with invalid action type" do
      extension = %{
        id: :test,
        label: "Test",
        icon: :home,
        path: "/test",
        action: "not_an_atom"
      }

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert Enum.any?(errors, &String.contains?(&1, "Field :action must be a atom"))
    end

    test "rejects extension with nil required fields" do
      extension = %{
        id: nil,
        label: "Test",
        icon: :home,
        path: "/test",
        action: :test
      }

      assert {:error, errors} = ExtensionSchema.validate(extension)
      assert Enum.any?(errors, &String.contains?(&1, "Field :id is required and cannot be nil"))
    end
  end

  describe "validate_all/1" do
    test "accepts a list of valid extensions" do
      extensions = [
        %{
          id: :subscription,
          label: "Subscription",
          icon: :credit_card,
          path: "/dashboard/subscription",
          action: :subscription
        },
        %{
          id: :support,
          label: "Support",
          icon: :chat_bubble_left_right,
          path: "/dashboard/support",
          action: :support
        }
      ]

      assert :ok = ExtensionSchema.validate_all(extensions)
    end

    test "rejects list with invalid extensions" do
      extensions = [
        %{
          id: :valid,
          label: "Valid",
          icon: :home,
          path: "/valid",
          action: :valid
        },
        %{
          id: :invalid,
          label: "Invalid",
          icon: :nonexistent,
          path: "/invalid",
          action: :invalid
        }
      ]

      assert {:error, errors} = ExtensionSchema.validate_all(extensions)
      assert [{1, error}] = errors
      assert String.contains?(error, "Invalid icon :nonexistent")
    end

    test "rejects empty extension map" do
      extensions = [%{}]

      assert {:error, errors} = ExtensionSchema.validate_all(extensions)
      assert errors != []
    end

    test "accepts empty list" do
      assert :ok = ExtensionSchema.validate_all([])
    end

    test "provides index information for multiple invalid extensions" do
      extensions = [
        %{id: :first},
        %{id: :second},
        %{
          id: :third,
          label: "Valid",
          icon: :home,
          path: "/valid",
          action: :valid
        }
      ]

      assert {:error, errors} = ExtensionSchema.validate_all(extensions)

      # Check that errors are indexed
      error_indices = Enum.uniq(Enum.map(errors, fn {index, _message} -> index end))
      assert 0 in error_indices
      assert 1 in error_indices
      refute 2 in error_indices
    end
  end

  describe "available_icons/0" do
    test "returns a list of atom icon names" do
      icons = ExtensionSchema.available_icons()

      assert is_list(icons)
      assert Enum.all?(icons, &is_atom/1)
      assert :home in icons
      assert :credit_card in icons
      assert :chat_bubble_left_right in icons
    end

    test "includes all expected icons" do
      icons = ExtensionSchema.available_icons()

      expected_icons = [
        :arrow_left,
        :bell,
        :calendar,
        :chat_bubble_left_right,
        :clock,
        :cloudron,
        :code,
        :credit_card,
        :docker,
        :grid,
        :home,
        :lock,
        :n8n,
        :paint_brush,
        :puzzle,
        :user,
        :video,
        :webhook
      ]

      for expected <- expected_icons do
        assert expected in icons,
               "Expected icon :#{expected} to be in available icons, but it wasn't"
      end
    end
  end

  describe "validate_and_log!/1" do
    setup do
      # Save original config
      original = Application.get_env(:tymeslot, :test_extensions)

      on_exit(fn ->
        # Restore original config
        if original do
          Application.put_env(:tymeslot, :test_extensions, original)
        else
          Application.delete_env(:tymeslot, :test_extensions)
        end
      end)

      :ok
    end

    test "succeeds with valid extensions" do
      Application.put_env(:tymeslot, :test_extensions, [
        %{
          id: :test,
          label: "Test",
          icon: :home,
          path: "/test",
          action: :test
        }
      ])

      assert :ok = ExtensionSchema.validate_and_log!(:test_extensions)
    end

    test "succeeds with no extensions configured" do
      Application.delete_env(:tymeslot, :test_extensions)
      assert :ok = ExtensionSchema.validate_and_log!(:test_extensions)
    end

    test "raises with invalid extensions" do
      Application.put_env(:tymeslot, :test_extensions, [
        %{id: :invalid}
      ])

      assert_raise RuntimeError, ~r/Dashboard extension validation failed/, fn ->
        ExtensionSchema.validate_and_log!(:test_extensions)
      end
    end
  end
end
