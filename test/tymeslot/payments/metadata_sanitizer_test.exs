defmodule Tymeslot.Payments.MetadataSanitizerTest do
  use ExUnit.Case, async: true

  @moduletag :payments

  alias Tymeslot.Payments.MetadataSanitizer

  describe "sanitize/2" do
    test "allows whitelisted keys" do
      metadata = %{"referral_code" => "ABC123", "utm_source" => "google"}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["referral_code"] == "ABC123"
      assert sanitized["utm_source"] == "google"
    end

    test "filters out non-whitelisted keys" do
      metadata = %{"referral_code" => "ABC123", "malicious_key" => "bad"}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["referral_code"] == "ABC123"
      refute Map.has_key?(sanitized, "malicious_key")
    end

    test "merges system metadata with precedence" do
      user_metadata = %{"referral_code" => "ABC123", "user_id" => "999"}
      system_metadata = %{"user_id" => "123", "product_identifier" => "pro"}

      assert {:ok, sanitized} = MetadataSanitizer.sanitize(user_metadata, system_metadata)

      # System metadata takes precedence
      assert sanitized["user_id"] == "123"
      assert sanitized["product_identifier"] == "pro"
      assert sanitized["referral_code"] == "ABC123"
    end

    test "strips HTML tags from values" do
      metadata = %{"referral_code" => "<script>alert('xss')</script>ABC"}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["referral_code"] == "ABC"
    end

    test "trims whitespace from values" do
      metadata = %{"referral_code" => "  ABC123  "}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["referral_code"] == "ABC123"
    end

    test "rejects values that are too long" do
      long_value = String.duplicate("A", 501)
      metadata = %{"referral_code" => long_value}
      assert {:error, :value_too_long} = MetadataSanitizer.sanitize(metadata)
    end

    test "accepts numeric values" do
      metadata = %{"custom_field_1" => 123}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["custom_field_1"] == 123
    end

    test "accepts boolean values" do
      metadata = %{"custom_field_1" => true}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["custom_field_1"] == true
    end

    test "accepts nil values" do
      metadata = %{"custom_field_1" => nil}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["custom_field_1"] == nil
    end

    test "converts atom keys to strings" do
      metadata = %{referral_code: "ABC123"}
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(metadata)
      assert sanitized["referral_code"] == "ABC123"
    end

    test "handles empty metadata" do
      assert {:ok, sanitized} = MetadataSanitizer.sanitize(%{})
      assert sanitized == %{}
    end
  end

  describe "sanitize!/2" do
    test "returns sanitized metadata on success" do
      metadata = %{"referral_code" => "ABC123"}
      sanitized = MetadataSanitizer.sanitize!(metadata)
      assert sanitized["referral_code"] == "ABC123"
    end

    test "raises on error" do
      long_value = String.duplicate("A", 501)
      metadata = %{"referral_code" => long_value}

      assert_raise ArgumentError, ~r/Metadata sanitization failed/, fn ->
        MetadataSanitizer.sanitize!(metadata)
      end
    end
  end

  describe "system_reserved?/1" do
    test "returns true for system-reserved keys" do
      assert MetadataSanitizer.system_reserved?("user_id")
      assert MetadataSanitizer.system_reserved?("product_identifier")
      assert MetadataSanitizer.system_reserved?("payment_type")
      assert MetadataSanitizer.system_reserved?(:user_id)
    end

    test "returns false for non-reserved keys" do
      refute MetadataSanitizer.system_reserved?("referral_code")
      refute MetadataSanitizer.system_reserved?("custom_field_1")
    end
  end

  describe "allowed_keys/0" do
    test "returns list of allowed user keys" do
      keys = MetadataSanitizer.allowed_keys()
      assert is_list(keys)
      assert "billing_interval" in keys
      assert "referral_code" in keys
      assert "utm_source" in keys
    end
  end
end
