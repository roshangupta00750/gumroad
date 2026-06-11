# frozen_string_literal: true

module Onetime
  class BackfillAudienceMembersIndex
    BATCH_SIZE = 1_000

    def self.process(from_id: 1)
      new.process(from_id:)
    end

    def process(from_id:)
      AudienceMember.where(id: from_id..).in_batches(of: BATCH_SIZE) do |batch|
        ReplicaLagWatcher.watch
        records = batch.to_a
        EsClient.bulk(
          index: AudienceMember.index_name,
          body: records.map { |record| { index: { _id: record.id, data: record.as_indexed_json } } },
        )
        puts records.last.id
      end
    end
  end
end
