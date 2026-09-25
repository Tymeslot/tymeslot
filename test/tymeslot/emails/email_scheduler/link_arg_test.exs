defmodule Tymeslot.Emails.EmailScheduler.LinkArgTest do
  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :unit

  alias Tymeslot.Emails.EmailScheduler.LinkArg

  @url "https://example.com/auth/reset-password/live-token-abc"

  test "stores the link encrypted and reads it back" do
    args = LinkArg.put(%{"action" => "send_password_reset"}, "reset_url", @url)

    refute Map.has_key?(args, "reset_url")
    refute Jason.encode!(args) =~ "live-token-abc"
    assert LinkArg.fetch(args, "reset_url") == {:ok, @url}
  end

  test "still reads the plaintext arg of a job enqueued before encryption" do
    assert LinkArg.fetch(%{"reset_url" => @url}, "reset_url") == {:ok, @url}
  end

  test "reports a tampered ciphertext as unreadable" do
    %{"reset_url_encrypted" => encoded} = LinkArg.put(%{}, "reset_url", @url)
    ciphertext = Base.decode64!(encoded)
    prefix_size = byte_size(ciphertext) - 1
    <<prefix::binary-size(^prefix_size), last>> = ciphertext
    tampered = Base.encode64(<<prefix::binary, Bitwise.bxor(last, 1)>>)

    assert LinkArg.fetch(%{"reset_url_encrypted" => tampered}, "reset_url") == :error
  end

  test "reports a missing or malformed link as unreadable" do
    assert LinkArg.fetch(%{}, "reset_url") == :error
    assert LinkArg.fetch(%{"reset_url_encrypted" => "%%% not base64"}, "reset_url") == :error
  end
end
