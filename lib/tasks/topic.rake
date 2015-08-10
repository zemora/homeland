namespace :topic do
  task rebuild_replies: :environment do
    Topic.asc(:id).each do |topic|
      puts "topic: #{topic.id}"
      topic.replies.rebuild!
    end
  end
end
