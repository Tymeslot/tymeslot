defmodule Tymeslot.Security.EncryptionKeyringConfigTest do
  # async: false — these tests mutate the global DATA_ENCRYPTION_KEY config and the
  # cached keyring in :persistent_term, so they must not run alongside other tests.
  use ExUnit.Case, async: false
  @moduletag :security

  import ExUnit.CaptureLog

  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Encryption.ConfigError

  @endpoint TymeslotWeb.Endpoint

  setup do
    original_encryption = Application.get_env(:tymeslot, Encryption)
    original_endpoint = Application.get_env(:tymeslot, @endpoint)

    on_exit(fn ->
      restore_env(Encryption, original_encryption)
      restore_env(@endpoint, original_endpoint)
      Encryption.reset_keyring()
    end)

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)

  defp put_secret_key_base(key) do
    base = Application.get_env(:tymeslot, @endpoint) || []
    Application.put_env(:tymeslot, @endpoint, Keyword.put(base, :secret_key_base, key))
    Encryption.reset_keyring()
  end

  defp put_data_encryption_key(value) do
    put_keys(data_encryption_key: value)
  end

  defp put_keys(config) do
    Application.put_env(:tymeslot, Encryption, config)
    Encryption.reset_keyring()
  end

  @key_1 Base.encode64(:crypto.strong_rand_bytes(48))
  @key_2 Base.encode64(:crypto.strong_rand_bytes(48))
  @key_3 Base.encode64(:crypto.strong_rand_bytes(48))

  test "falls back to the legacy format when DATA_ENCRYPTION_KEY is absent" do
    put_data_encryption_key(nil)

    assert Encryption.current_version() == 0

    encrypted = Encryption.encrypt("legacy-write")
    # No version prefix — a bare nonce <> tag <> ciphertext envelope.
    <<_nonce::binary-12, _tag::binary-16, _ciphertext::binary>> = encrypted
    assert Encryption.decrypt(encrypted) == "legacy-write"

    # The value stays readable once the dedicated key is configured, proving it
    # was written in the still-supported legacy format.
    put_data_encryption_key("RsxoYoIVSu/K+QDV2yukDwTFD3wDyDSFxuGmoauNAX0FcXJF58dAz5LhEyiNqhFP")

    assert Encryption.current_version() == 1
    assert Encryption.decrypt(encrypted) == "legacy-write"
    refute Encryption.current?(encrypted)
  end

  test "rotating SECRET_KEY_BASE does not break decryption of current-version values" do
    encrypted = Encryption.encrypt("still-readable")

    # Rotate the session-signing secret — the whole point of the decoupling is
    # that this no longer touches data-at-rest, which is keyed on DATA_ENCRYPTION_KEY.
    put_secret_key_base(String.duplicate("z", 64))

    assert Encryption.decrypt(encrypted) == "still-readable"
  end

  test "raises when DATA_ENCRYPTION_KEY is not valid Base64" do
    put_data_encryption_key("not valid base64 !!!")

    assert_raise ConfigError, ~r/valid Base64/, fn -> Encryption.encrypt("x") end
  end

  test "raises when DATA_ENCRYPTION_KEY decodes to fewer than 32 bytes" do
    short_key = Base.encode64(:crypto.strong_rand_bytes(16))
    put_data_encryption_key(short_key)

    assert_raise ConfigError, ~r/at least 32 bytes/, fn -> Encryption.encrypt("x") end
  end

  describe "DATA_ENCRYPTION_KEYS" do
    test "the first entry is the primary and the others stay readable" do
      put_keys(data_encryption_keys: "1:#{@key_1}")
      written_under_1 = Encryption.encrypt("before rotation")

      put_keys(data_encryption_keys: "2:#{@key_2}, 1:#{@key_1}")

      assert Encryption.current_version() == 2
      assert <<2, _rest::binary>> = Encryption.encrypt("after rotation")
      assert Encryption.decrypt(written_under_1) == "before rotation"
      refute Encryption.current?(written_under_1)
    end

    test "DATA_ENCRYPTION_KEY is key 1, so leaving it out of the list strands nothing" do
      put_keys(data_encryption_key: @key_1)
      written_under_1 = Encryption.encrypt("single key")

      put_keys(data_encryption_key: @key_1, data_encryption_keys: "2:#{@key_2}")

      assert Encryption.current_version() == 2
      assert Encryption.decrypt(written_under_1) == "single key"
    end

    test "a single DATA_ENCRYPTION_KEY still writes the v1 format an older release reads" do
      put_keys(data_encryption_key: @key_1)

      <<1, nonce::binary-12, tag::binary-16, ciphertext::binary>> = Encryption.encrypt("v1")

      # The envelope and key derivation every earlier release decrypts with,
      # restated independently of the keyring code.
      key = :crypto.hash(:sha256, Base.decode64!(@key_1))

      assert :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               key,
               nonce,
               ciphertext,
               "Tymeslot.Encryption",
               tag,
               false
             ) == "v1"
    end

    test "an entry repeating DATA_ENCRYPTION_KEY under id 1 is accepted" do
      put_keys(data_encryption_key: @key_1, data_encryption_keys: "2:#{@key_2},1:#{@key_1}")

      assert Encryption.current_version() == 2
    end

    test "refuses a different key under id 1 than DATA_ENCRYPTION_KEY" do
      put_keys(data_encryption_key: @key_1, data_encryption_keys: "2:#{@key_2},1:#{@key_3}")

      error = assert_raise ConfigError, fn -> Encryption.validate!() end
      assert Exception.message(error) =~ "different key under id 1"
      refute_key_material(Exception.message(error))
    end

    test "refuses an id listed twice" do
      put_keys(data_encryption_keys: "2:#{@key_2},2:#{@key_3}")

      error = assert_raise ConfigError, fn -> Encryption.validate!() end
      assert Exception.message(error) =~ "id 2 more than once"
    end

    for entry <- ["0:KEY", "256:KEY", "two:KEY", "KEY"] do
      test "refuses the malformed entry #{inspect(entry)}" do
        put_keys(data_encryption_keys: String.replace(unquote(entry), "KEY", @key_2))

        error = assert_raise ConfigError, fn -> Encryption.validate!() end
        assert Exception.message(error) =~ "entry 1 must be `<id>:<base64 key>`"
        refute_key_material(Exception.message(error))
      end
    end

    test "refuses an entry whose key is too short, naming its position" do
      short = Base.encode64(:crypto.strong_rand_bytes(16))
      put_keys(data_encryption_keys: "2:#{@key_2},1:#{short}")

      error = assert_raise ConfigError, fn -> Encryption.validate!() end
      assert Exception.message(error) =~ "entry 2 must decode to at least 32 bytes"
      refute_key_material(Exception.message(error))
    end
  end

  describe "a rolling rotation across nodes with different key lists" do
    # Each node caches its own keyring; swapping the config and resetting the
    # cache stands in for asking the other node.
    @old_node [data_encryption_key: @key_1]
    @phase_1_node [data_encryption_key: @key_1, data_encryption_keys: "1:#{@key_1},2:#{@key_2}"]
    @phase_2_node [data_encryption_key: @key_1, data_encryption_keys: "2:#{@key_2},1:#{@key_1}"]

    test "phase 1 adds the new key without writing with it, so older nodes read everything" do
      put_keys(@phase_1_node)
      written_in_phase_1 = Encryption.encrypt("phase 1")

      assert <<1, _rest::binary>> = written_in_phase_1

      put_keys(@old_node)
      assert Encryption.decrypt(written_in_phase_1) == "phase 1"
    end

    test "a phase 1 node reads what a promoted node writes, and the reverse" do
      put_keys(@phase_2_node)
      from_promoted = Encryption.encrypt("from promoted")

      put_keys(@phase_1_node)
      from_phase_1 = Encryption.encrypt("from phase 1")
      assert Encryption.decrypt(from_promoted) == "from promoted"

      put_keys(@phase_2_node)
      assert Encryption.decrypt(from_phase_1) == "from phase 1"
    end

    test "a value the old key writes after promotion stays readable and is left for the sweep" do
      put_keys(@phase_2_node)
      _promoted_write = Encryption.encrypt("promoted")

      # A node (or a rolled-back image) still on the old configuration writes.
      put_keys(@old_node)
      late_write = Encryption.encrypt("late")

      put_keys(@phase_2_node)
      assert Encryption.decrypt(late_write) == "late"
      refute Encryption.current?(late_write)
    end

    test "a node without the new key cannot read a promoted value, so phase 1 must finish first" do
      put_keys(@phase_2_node)
      from_promoted = Encryption.encrypt("from promoted")

      put_keys(@old_node)
      assert Encryption.decrypt_with_status(from_promoted) == {:error, :requires_reencryption}
    end
  end

  describe "LEGACY_KEY_RETIRED" do
    test "v0 values stop opening, and open again once the flag is unset" do
      put_keys(data_encryption_key: nil)
      legacy_value = Encryption.encrypt("legacy")

      put_keys(data_encryption_key: @key_1, legacy_key_retired: true)

      assert Encryption.legacy_key_retired?()
      assert Encryption.decrypt_with_status(legacy_value) == {:error, :requires_reencryption}
      assert Encryption.decrypt(Encryption.encrypt("new")) == "new"

      put_keys(data_encryption_key: @key_1)

      refute Encryption.legacy_key_retired?()
      assert Encryption.decrypt(legacy_value) == "legacy"
    end

    test "no longer needs SECRET_KEY_BASE to derive a key" do
      put_keys(data_encryption_key: @key_1, legacy_key_retired: true)
      put_secret_key_base("too short")

      assert Encryption.validate!() == :ok
      assert Encryption.decrypt(Encryption.encrypt("x")) == "x"
    end

    test "refuses to start with no versioned key to write with" do
      put_keys(data_encryption_key: nil, legacy_key_retired: true)

      assert_raise ConfigError, ~r/no key to write with/, fn -> Encryption.validate!() end
    end
  end

  describe "validate!/0" do
    test "raises at boot for a malformed key, before any value is touched" do
      put_data_encryption_key("not valid base64 !!!")

      assert_raise ConfigError, ~r/valid Base64/, fn -> Encryption.validate!() end
    end

    test "accepts a working configuration" do
      put_keys(data_encryption_key: @key_1, data_encryption_keys: "2:#{@key_2}")

      assert Encryption.validate!() == :ok
    end

    test "refuses a SECRET_KEY_BASE too short to derive the legacy key" do
      put_keys(data_encryption_key: @key_1)
      put_secret_key_base("too short")

      error = assert_raise ConfigError, fn -> Encryption.validate!() end
      assert error.reason =~ "SECRET_KEY_BASE must be at least 64 bytes"
      assert error.fix =~ "openssl rand -base64 64"
    end
  end

  describe "check_config/0" do
    test "logs what is wrong and how to fix it, and returns the error instead of raising" do
      put_data_encryption_key("abc-def_ghi")

      log =
        capture_log(fn ->
          assert {:error, %ConfigError{reason: "DATA_ENCRYPTION_KEY must be valid Base64"}} =
                   Encryption.check_config()
        end)

      assert log =~ "Tymeslot cannot start: the data encryption key configuration is invalid."
      assert log =~ "DATA_ENCRYPTION_KEY must be valid Base64."
      assert log =~ "URL-safe characters (`-`, `_`) are refused."
      assert log =~ "openssl rand -base64 48"
    end

    test "logs nothing for a working configuration" do
      put_data_encryption_key(@key_1)

      log = capture_log(fn -> assert Encryption.check_config() == :ok end)

      refute log =~ "cannot start"
    end
  end

  defp refute_key_material(message) do
    for key <- [@key_1, @key_2, @key_3], do: refute(message =~ key)
  end
end
