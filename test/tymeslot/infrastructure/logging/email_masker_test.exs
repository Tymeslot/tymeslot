defmodule Tymeslot.Infrastructure.Logging.EmailMaskerTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Logging.EmailMasker

  test "masks every address in a text and nothing else, idempotently" do
    text = "Sent to jane.doe@example.com and bob@mail.example.org at 10:00"
    masked = EmailMasker.mask_emails(text)

    assert masked == "Sent to j***@example.com and b***@mail.example.org at 10:00"
    assert EmailMasker.mask_emails(masked) == masked
  end

  test "masks a value only when it is a single address" do
    assert EmailMasker.mask_email("jane@example.com") == "j***@example.com"
    assert EmailMasker.mask_email("Jane <jane@example.com>") == nil
    assert EmailMasker.mask_email("not an address") == nil
  end
end
