class Handler
  include Messaging::Handle
  include Messaging::StreamName

  dependency :write, Messaging::Postgres::Write
  dependency :clock, Clock::UTC
  dependency :store, Store

  def configure
    Messaging::Postgres::Write.configure(self)
    Clock::UTC.configure(self)
    Store.configure(self)
  end

  category :account

  handle Withdraw do |withdraw|
    account_id = withdraw.account_id

    account = store.fetch(account_id)

    time = clock.iso8601

    stream_name = stream_name(account_id)

    unless account.sufficient_funds?(withdraw.amount)
      withdrawal_rejected = WithdrawalRejected.follow(withdraw)
      withdrawal_rejected.time = time

      write.(withdrawal_rejected, stream_name)

      return
    end

    withdrawn = Withdrawn.follow(withdraw)
    withdrawn.processed_time = time

    write.(withdrawn, stream_name)
  end
end

class Withdraw
  include Messaging::Message

  attribute :account_id, String
  attribute :amount, Numeric
  attribute :time, String
end

class Withdrawn
  include Messaging::Message

  attribute :account_id, String
  attribute :amount, Numeric
  attribute :time, String
  attribute :processed_time, String
end

class WithdrawalRejected
  include Messaging::Message

  attribute :account_id, String
  attribute :amount, Numeric
  attribute :time, String
end

class Account
  include Schema::DataStructure

  attribute :id, String
  attribute :balance, Numeric, default: 0

  def withdraw(amount)
    self.balance -= amount
  end

  def sufficient_funds?(amount)
    balance >= amount
  end
end

class Projection
  include EntityProjection

  entity_name :account

  apply Withdrawn do |withdrawn|
    account.id = withdrawn.account_id

    amount = withdrawn.amount

    account.withdraw(amount)
  end
end

class Store
  include EntityStore

  category :account
  entity Account
  projection Projection
  reader MessageStore::Postgres::Read
end

class Consumer
  include Consumer::Postgres

  handler Handler
end

Consumer.start('account:command')

