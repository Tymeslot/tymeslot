defmodule Tymeslot.Security.HoneypotTest do
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :unit

  alias Tymeslot.Security.Honeypot

  describe "tripped?/1" do
    test "is tripped by any filled-in value" do
      assert Honeypot.tripped?(%{"website" => "http://spam.example"})
    end

    test "is tripped by whitespace, which no human types into a hidden field" do
      assert Honeypot.tripped?(%{"website" => "  "})
    end

    test "is not tripped by an empty field" do
      refute Honeypot.tripped?(%{"website" => ""})
    end

    test "is not tripped when the field is absent or not a string" do
      refute Honeypot.tripped?(%{"email" => "human@example.com"})
      refute Honeypot.tripped?(%{"website" => 123})
    end
  end
end
