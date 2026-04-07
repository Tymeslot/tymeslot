defmodule Tymeslot.Repo.Migrations.AddWebhookTokenField do
  use Ecto.Migration
  import Ecto.Query

  def up do
    alter table(:webhooks) do
      add :webhook_token_encrypted, :binary
    end

    flush()

    # Generate and encrypt tokens for existing webhooks
    Tymeslot.Repo.transaction(fn ->
      Tymeslot.Repo.stream(Tymeslot.Webhooks.WebhookSchema)
      |> Enum.each(fn webhook ->
        token = "ts_" <> Base.encode64(:crypto.strong_rand_bytes(24), padding: false)
        encrypted_token = Tymeslot.Security.Encryption.encrypt(token)

        Tymeslot.Repo.update_all(
          from(w in Tymeslot.Webhooks.WebhookSchema, where: w.id == ^webhook.id),
          set: [webhook_token_encrypted: encrypted_token]
        )
      end)
    end)

    alter table(:webhooks) do
      modify :webhook_token_encrypted, :binary, null: false
    end
  end

  def down do
    alter table(:webhooks) do
      remove :webhook_token_encrypted
    end
  end
end
