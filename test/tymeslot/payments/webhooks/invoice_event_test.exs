defmodule Tymeslot.Payments.Webhooks.InvoiceEventTest do
  use ExUnit.Case, async: true
  @moduletag :payments
  @moduletag :unit

  alias Tymeslot.Payments.Webhooks.InvoiceEvent

  describe "from_payload/2 metadata_user_id" do
    test "reads a string user_id from parent.subscription_details.metadata (Basil)" do
      invoice = %{
        "id" => "in_basil",
        "parent" => %{
          "subscription_details" => %{"metadata" => %{"user_id" => "42"}}
        }
      }

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == 42
    end

    test "reads an integer user_id from parent.subscription_details.metadata" do
      invoice = %{
        "id" => "in_basil_int",
        "parent" => %{
          "subscription_details" => %{"metadata" => %{"user_id" => 42}}
        }
      }

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == 42
    end

    test "falls back to the pre-Basil subscription_details.metadata shape" do
      invoice = %{
        "id" => "in_pre_basil",
        "subscription_details" => %{"metadata" => %{"user_id" => "43"}}
      }

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == 43
    end

    test "prefers parent.subscription_details.metadata over the pre-Basil shape when both are present" do
      invoice = %{
        "id" => "in_both_shapes",
        "parent" => %{
          "subscription_details" => %{"metadata" => %{"user_id" => "42"}}
        },
        "subscription_details" => %{"metadata" => %{"user_id" => "99"}}
      }

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == 42
    end

    test "is nil when no metadata is present" do
      invoice = %{"id" => "in_no_metadata"}

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == nil
    end

    test "is nil when metadata carries no user_id" do
      invoice = %{
        "id" => "in_no_user_id",
        "parent" => %{"subscription_details" => %{"metadata" => %{}}}
      }

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == nil
    end

    test "is nil for a malformed user_id" do
      invoice = %{
        "id" => "in_malformed",
        "parent" => %{
          "subscription_details" => %{"metadata" => %{"user_id" => "not-a-number"}}
        }
      }

      assert InvoiceEvent.from_payload(invoice, "sub_1").metadata_user_id == nil
    end
  end
end
