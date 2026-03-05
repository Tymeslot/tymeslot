defmodule Tymeslot.Telegram.LinkTokenTest do
  use Tymeslot.DataCase, async: true

  @moduletag :telegram
  @moduletag :unit

  alias Tymeslot.Telegram.LinkToken

  describe "sign/2 and verify/1" do
    test "round-trips successfully" do
      token = LinkToken.sign(42, 99)
      assert {:ok, {42, 99}} = LinkToken.verify(token)
    end

    test "rejects expired token" do
      token = LinkToken.sign(42, 99)
      assert {:error, :expired} = LinkToken.verify(token, max_age: 0)
    end

    test "rejects tampered token" do
      assert {:error, :invalid} = LinkToken.verify("tampered_token")
    end
  end
end
