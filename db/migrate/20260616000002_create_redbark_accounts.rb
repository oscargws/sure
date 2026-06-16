class CreateRedbarkAccounts < ActiveRecord::Migration[7.2]
  def change
    create_table :redbark_accounts, id: :uuid do |t|
      t.references :redbark_item, null: false, foreign_key: true, type: :uuid
      t.string :name
      t.string :account_id
      t.string :connection_id
      t.string :currency
      t.decimal :current_balance, precision: 19, scale: 4
      t.string :account_status
      t.string :account_type
      t.string :provider

      t.jsonb :institution_metadata
      t.jsonb :raw_payload
      t.jsonb :raw_transactions_payload

      t.timestamps
    end

    add_index :redbark_accounts, :account_id
    add_index :redbark_accounts,
              [ :redbark_item_id, :account_id ],
              unique: true,
              name: "index_redbark_accounts_on_item_and_account_id",
              where: "account_id IS NOT NULL"
  end
end
