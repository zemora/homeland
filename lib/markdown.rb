require 'rails'
require 'rails_autolink'
require 'kramdown'
require 'singleton'

module Kramdown
  module Parser
    class RubyChina < GFM
      def parse_table

      end
    end
  end
end

# module Redcarpet
#   module Render
#     class HTMLwithSyntaxHighlight < HTML
#       include Rouge::Plugins::Redcarpet
#
#       def initialize(extensions = {})
#         super(extensions.merge(xhtml: true,
#                                no_styles: true,
#                                escape_html: true,
#                                hard_wrap: true,
#                                link_attributes: { target: '_blank' }))
#       end
#
#       def block_code(code, language)
#         language.downcase! if language.is_a?(String)
#         html = super(code, language)
#         # 将最后行的 "\n\n" 替换成回 "\n", rouge 0.3.2 的 Bug 导致
#         html.gsub!(%r{([\n]+)</code>}, '</code>')
#         html
#       end
#
#       def table(header, body)
#         %(<table class="table table-bordered table-striped">#{header}#{body}</table>)
#       end
#
#       def autolink(link, link_type)
#         # return link
#         if link_type.to_s == 'email'
#           link
#         else
#           begin
#             # 防止 C 的 autolink 出来的内容有编码错误，万一有就直接跳过转换
#             # 比如这句:
#             # 此版本并非线上的http://yavaeye.com的源码.
#             link.match(/.+?/)
#           rescue
#             return link
#           end
#           # Fix Chinese neer the URL
#           bad_text = link.match(%r{[^\w:@/\-~,$!.=?&#+|%]+}im).to_s
#           link.gsub!(bad_text, '')
#           %(<a href="#{link}" rel="nofollow" target="_blank">#{link}</a>#{bad_text})
#         end
#       end
#     end
#
#     class HTMLwithTopic < HTMLwithSyntaxHighlight
#       def header(text, header_level)
#         l = header_level <= 2 ? 2 : header_level
#         raw_text = Nokogiri::HTML(text).xpath('//text()')
#         %(<h#{l} id="#{raw_text}">#{text}</h#{l}>)
#       end
#     end
#   end
# end

class MarkdownConverter
  include Singleton
  include ActionView::Helpers::TextHelper
  include ActionView::Helpers::UrlHelper

  def self.convert(text)
    instance.convert(text)
  end

  def convert(text)
    text = auto_link(text, html: { target: '_blank' })
    @document = Kramdown::Document.new(text, input: 'GFM',
                                             header_offset: 1,
                                             remove_span_html_tags: true,
                                             transliterated_header_ids: true,
                                             syntax_highlighter: :rouge)
    @document.to_html
  end
end

class MarkdownTopicConverter < MarkdownConverter
  def self.format(raw)
    instance.format(raw)
  end

  def format(raw)
    text = raw.clone
    return '' if text.blank?

    convert_bbcode_img(text)
    users = normalize_user_mentions(text)

    # 如果 ``` 在刚刚换行的时候 Redcapter 无法生成正确，需要两个换行
    # text.gsub!("\n```", "\n\n```")

    result = convert(text)

    doc = Nokogiri::HTML.fragment(result)
    add_class_to_table(doc)
    link_mention_floor(doc)
    link_mention_user(doc, users)
    replace_emoji(doc)

    return doc.to_html.strip
  # rescue => e
  #   Rails.logger.error "MarkdownTopicConverter.format ERROR: #{e}"
  #   return text
  end

  private

  # convert bbcode-style image tag [img]url[/img] to markdown syntax ![alt](url)
  def convert_bbcode_img(text)
    text.gsub!(%r{\[img\](.+?)\[/img\]}i) { "![#{image_alt Regexp.last_match(1)}](#{Regexp.last_match(1)})" }
  end

  def add_class_to_table(doc)
    doc.search('table').each do |node|
      node['class'] = 'table table-bordered table-striped'
    end
  end

  def image_alt(src)
    File.basename(src, '.*').capitalize
  end

  # borrow from html-pipeline
  def ancestors?(node, tags)
    while (node = node.parent)
      break true if tags.include?(node.name.downcase)
    end
  end

  # convert '#N楼' to link
  # Refer to emoji_filter in html-pipeline
  def link_mention_floor(doc)
    doc.search('text()').each do |node|
      content = node.to_html
      next unless content.include?('#')
      next if ancestors?(node, %w(pre code))

      html = content.gsub(/#(\d+)([楼樓Ff])/) do
        %(<a href="#reply#{Regexp.last_match(1)}" class="at_floor" data-floor="#{Regexp.last_match(1)}">##{Regexp.last_match(1)}#{Regexp.last_match(2)}</a>)
      end

      next if html == content
      node.replace(html)
    end
  end

  NORMALIZE_USER_REGEXP = /(^|[^a-zA-Z0-9_!#\$%&*@＠])@([a-zA-Z0-9_]{1,20})/io
  LINK_USER_REGEXP = /(^|[^a-zA-Z0-9_!#\$%&*@＠])@(user[0-9]{1,6})/io

  # rename user name using incremental id
  def normalize_user_mentions(text)
    users = []

    text.gsub!(NORMALIZE_USER_REGEXP) do
      prefix = Regexp.last_match(1)
      user = Regexp.last_match(2)
      users.push(user)
      "#{prefix}@user#{users.size}"
    end

    users
  end

  def link_mention_user(doc, users)
    link_mention_user_in_text(doc, users)
    link_mention_user_in_code(doc, users)
  end

  # convert '@user' to link
  # match any user even not exist.
  def link_mention_user_in_text(doc, users)
    doc.search('text()').each do |node|
      content = node.to_html
      next unless content.include?('@')
      in_code = ancestors?(node, %w(pre code))
      content.gsub!(LINK_USER_REGEXP) do
        prefix = Regexp.last_match(1)
        user_placeholder = Regexp.last_match(2)
        user_id = user_placeholder.sub(/^user/, '').to_i
        user = users[user_id - 1] || user_placeholder

        if in_code
          "#{prefix}@#{user}"
        else
          %(#{prefix}<a href="/#{user}" class="at_user" title="@#{user}"><i>@</i>#{user}</a>)
        end
      end

      node.replace(content)
    end
  end

  # Some code highlighter mark `@` and following characters as different
  # syntax class.
  def link_mention_user_in_code(doc, users)
    doc.css('pre.highlight span').each do |node|
      next unless node.previous && node.previous.inner_html == '@' && node.inner_html =~ /\Auser(\d+)\z/
      user_id = Regexp.last_match(1)
      user = users[user_id.to_i - 1]
      node.inner_html = user if user
    end
  end

  def replace_emoji(doc)
    doc.search('text()').each do |node|
      content = node.to_html
      next unless content.include?(':')
      next if ancestors?(node, %w(pre code))

      html = content.gsub(/:(\S+):/) do |emoji|
        emoji_code = emoji # .gsub("|", "_")
        emoji      = emoji_code.delete(':')

        if EMOJI_LIST.include?(emoji)
          file_name = "#{emoji.gsub('+', 'plus')}.png"

          %(<img src="#{upload_url}/assets/emojis/#{file_name}" class="emoji" ) +
          %(title="#{emoji_code}" alt="" />)
        else
          emoji_code
        end
      end

      next if html == content
      node.replace(html)
    end
  end

  # for testing
  def upload_url
    Setting.upload_url
  end
end

EMOJI_LIST = %w{+1 -1 0 1 100 109 1234 2 3 4 5 6 7 8 8ball 9 a ab
  abc abcd accept aerial_tramway airplane alarm_clock alien ambulance
  anchor angel anger angry anguished ant apple aquarius aries arrow_backward
  arrow_double_down arrow_double_up arrow_down arrow_down_small arrow_forward
  arrow_heading_down arrow_heading_up arrow_left arrow_lower_left arrow_lower_right
  arrow_right arrow_right_hook arrow_up arrow_up_down arrow_up_small arrow_upper_left
  arrow_upper_right arrows_clockwise arrows_counterclockwise art articulated_lorry
  astonished atm b baby baby_bottle baby_chick baby_symbol baggage_claim balloon
  ballot_box_with_check bamboo banana bangbang bank bar_chart barber baseball
  basketball bath bathtub battery bear beer beers beetle beginner bell bento
  bicyclist bike bikini bird birthday black_circle black_joker black_nib black_square
  black_square_button blossom blowfish blue_book blue_car blue_heart blush boar
  boat bomb book bookmark bookmark_tabs books boom boot bouquet bow bowling bowtie
  boy bread bride_with_veil bridge_at_night briefcase broken_heart bug bulb bullettrain_front
  bullettrain_side bus busstop bust_in_silhouette busts_in_silhouette cactus cake calendar
  calling camel camera cancer candy capital_abcd capricorn car card_index carousel_horse
  cat cat2 cd chart chart_with_downwards_trend chart_with_upwards_trend checkered_flag
  cherries cherry_blossom chestnut chicken children_crossing chocolate_bar christmas_tree
  church cinema circus_tent city_sunrise city_sunset cl clap clapper clipboard clock1 clock10
  clock1030 clock11 clock1130 clock12 clock1230 clock130 clock2 clock230 clock3 clock330
  clock4 clock430 clock5 clock530 clock6 clock630 clock7 clock730 clock8 clock830 clock9
  clock930 closed_book closed_lock_with_key closed_umbrella cloud clubs cn cocktail coffee
  cold_sweat collision computer confetti_ball confounded confused congratulations construction
  construction_worker convenience_store cookie cool cop copyright corn couple couple_with_heart
  couplekiss cow cow2 credit_card crocodile crossed_flags crown cry crying_cat_face crystal_ball
  cupid curly_loop currency_exchange curry custard customs cyclone dancer dancers dango dart dash
  date de deciduous_tree department_store diamond_shape_with_a_dot_inside diamonds disappointed
  disappointed_relieved dizzy dizzy_face do_not_litter dog dog2 dollar dolls dolphin door doughnut
  dragon dragon_face dress dromedary_camel droplet dvd e-mail ear ear_of_rice earth_africa
  earth_americas earth_asia egg eggplant egplant eight eight_pointed_black_star eight_spoked_asterisk
  electric_plug elephant email end envelope es euro european_castle european_post_office
  evergreen_tree exclamation expressionless eyeglasses eyes facepunch factory fallen_leaf family
  fast_forward fax fearful feelsgood feet ferris_wheel file_folder finnadie fire fire_engine
  fireworks first_quarter_moon first_quarter_moon_with_face fish fish_cake
  fishing_pole_and_fish fist five flags flashlight floppy_disk flower_playing_cards
  flushed foggy football fork_and_knife fountain four four_leaf_clover fr free fried_shrimp
  fries frog frowning fu fuelpump full_moon full_moon_with_face game_die gb gem gemini ghost
  gift gift_heart girl globe_with_meridians goat goberserk godmode golf grapes green_apple
  green_book green_heart grey_exclamation grey_question grimacing grin grinning guardsman
  guitar gun haircut hamburger hammer hamster hand handbag hankey hash hatched_chick hatching_chick
  headphones hear_no_evil heart heart_decoration heart_eyes heart_eyes_cat heartbeat heartpulse
  hearts heavy_check_mark heavy_division_sign heavy_dollar_sign heavy_exclamation_mark
  heavy_minus_sign heavy_multiplication_x heavy_plus_sign helicopter herb hibiscus high_brightness
  high_heel hocho honey_pot honeybee horse horse_racing hospital hotel hotsprings hourglass
  hourglass_flowing_sand house house_with_garden hurtrealbad hushed ice_cream icecream id ideograph_advantage imp
  inbox_tray incoming_envelope information_desk_person information_source innocent interrobang
  iphone it izakaya_lantern jack_o_lantern japan japanese_castle japanese_goblin japanese_ogre
  jeans joy joy_cat jp key keycap_ten kimono kiss kissing kissing_cat kissing_closed_eyes kissing_face
  kissing_heart kissing_smiling_eyes koala koko kr large_blue_circle large_blue_diamond
  large_orange_diamond last_quarter_moon last_quarter_moon_with_face laughing leaves ledger
  left_luggage left_right_arrow leftwards_arrow_with_hook lemon leo leopard libra light_rail
  link lips lipstick lock lock_with_ink_pen lollipop loop loudspeaker love_hotel love_letter
  low_brightness m mag mag_right mahjong mailbox mailbox_closed mailbox_with_mail mailbox_with_no_mail
  man man_with_gua_pi_mao man_with_turban mans_shoe maple_leaf mask massage meat_on_bone mega melon
  memo mens metal metro microphone microscope milky_way minibus minidisc mobile_phone_off money_with_wings
  moneybag monkey monkey_face monorail moon mortar_board mount_fuji mountain_bicyclist mountain_cableway
  mountain_railway mouse mouse2 movie_camera moyai muscle mushroom musical_keyboard musical_note
  musical_score mute nail_care name_badge neckbeard necktie negative_squared_cross_mark neutral_face
  new new_moon new_moon_with_face newspaper ng nine no_bell no_bicycles no_entry no_entry_sign no_good
  no_mobile_phones no_mouth no_pedestrians no_smoking non-potable_water nose notebook
  notebook_with_decorative_cover notes nut_and_bolt o o2 ocean octocat octopus oden office ok ok_hand
  ok_woman older_man older_woman on oncoming_automobile oncoming_bus oncoming_police_car oncoming_taxi
  one open_file_folder open_hands open_mouth ophiuchus orange_book outbox_tray ox page_facing_up
  page_with_curl pager palm_tree panda_face paperclip parking part_alternation_mark partly_sunny
  passport_control paw_prints peach pear pencil pencil2 penguin pensive performing_arts persevere
  person_frowning person_with_blond_hair person_with_pouting_face phone pig pig2 pig_nose pill
  pineapple pisces pizza plus1 point_down point_left point_right point_up point_up_2 police_car
  poodle poop post_office postal_horn postbox potable_water pouch poultry_leg pound pouting_cat
  pray princess punch purple_heart purse pushpin put_litter_in_its_place question rabbit rabbit2
  racehorse radio radio_button rage rage1 rage2 rage3 rage4 railway_car rainbow raised_hand raised_hands
  raising_hand ram ramen rat recycle red_car red_circle registered relaxed relieved repeat repeat_one
  restroom revolving_hearts rewind ribbon rice rice_ball rice_cracker rice_scene ring rocket
  roller_coaster rooster rose rotating_light round_pushpin rowboat ru rugby_football runner running
  running_shirt_with_sash sa sagittarius sailboat sake sandal santa satellite satisfied saxophone
  school school_satchel scissors scorpius scream scream_cat scroll seat secret see_no_evil
  seedling seven shaved_ice sheep shell ship shipit shirt shit shoe shower signal_strength six
  six_pointed_star ski skull sleeping sleepy slot_machine small_blue_diamond small_orange_diamond
  small_red_triangle small_red_triangle_down smile smile_cat smiley smiley_cat smiling_imp smirk
  smirk_cat smoking snail snake snowboarder snowflake snowman sob soccer soon sos sound space_invader
  spades spaghetti sparkler sparkles sparkling_heart speak_no_evil speaker speech_balloon speedboat
  squirrel star star2 stars station statue_of_liberty steam_locomotive stew straight_ruler strawberry
  stuck_out_tongue stuck_out_tongue_closed_eyes stuck_out_tongue_winking_eye sun_with_face sunflower
  sunglasses sunny sunrise sunrise_over_mountains surfer sushi suspect suspension_railway sweat
  sweat_drops sweat_smile sweet_potato swimmer symbols syringe tada tanabata_tree tangerine taurus
  taxi tea telephone telephone_receiver telescope tennis tent thought_balloon three thumbsdown
  thumbsup ticket tiger tiger2 tired_face tm toilet tokyo_tower tomato tongue tongue2 top tophat
  tractor traffic_light train train2 tram triangular_flag_on_post triangular_ruler trident triumph
  trolleybus trollface trophy tropical_drink tropical_fish truck trumpet tshirt tulip turtle tv
  twisted_rightwards_arrows two two_hearts two_men_holding_hands two_women_holding_hands
  u5272 u5408 u55b6 u6307 u6708 u6709 u6e80 u7121 u7533 u7981 u7a7a uk umbrella unamused
  underage unlock up us v vertical_traffic_light vhs vibration_mode video_camera video_game
  violin virgo volcano vs walking waning_crescent_moon waning_gibbous_moon warning watch
  water_buffalo watermelon wave wavy_dash waxing_crescent_moon waxing_gibbous_moon wc weary
  wedding whale whale2 wheelchair white_check_mark white_circle white_flower white_square
  white_square_button wind_chime wine_glass wink wink2 wolf woman womans_clothes womans_hat
  womens worried wrench x yellow_heart yen yum zap zero zzz}

MARKDOWN_DOC = %(# Guide

这是一篇讲解如何正确使用 Ruby China 的 **Markdown** 的排版示例，学会这个很有必要，能让你的文章有更佳清晰的排版。

> 引用文本：Markdown is a text formatting syntax inspired

## 语法指导

### 普通内容

这段内容展示了在内容里面一些小的格式，比如：

- **加粗** - `**加粗**`
- *倾斜* - `*倾斜*`
- ~~删除线~~ - `~~删除线~~`
- `Code 标记` - `\`Code 标记\``
- [超级链接](http://github.com) - `[超级链接](http://github.com)`
- [huacnlee@gmail.com](mailto:huacnlee@gmail.com) - `[huacnlee@gmail.com](mailto:huacnlee@gmail.com)`

### 提及用户

@huacnlee @rei @lgn21st ... 通过 @ 可以在发帖和回帖里面提及用户，信息提交以后，被提及的用户将会收到系统通知。以便让他来关注这个帖子或回帖。

### 表情符号 Emoji

Ruby China 支持表情符号，你可以用系统默认的 Emoji 符号（无法支持 Chrome 以及 Windows 用户）。
也可以用图片的表情，输入 `:` 将会出现智能提示。

#### 一些表情例子

:smile: :laughing: :dizzy_face: :sob: :cold_sweat: :sweat_smile:  :cry: :triumph: :heart_eyes:  :satisfied: :relaxed: :sunglasses: :weary:

:+1: :-1: :100: :clap: :bell: :gift: :question: :bomb: :heart: :coffee: :cyclone: :bow: :kiss: :pray: :shit: :sweat_drops: :exclamation: :anger:

更多表情请访问：[http://www.emoji-cheat-sheet.com](http://www.emoji-cheat-sheet.com)

### 大标题 - Heading 3

你可以选择使用 H2 至 H6，使用 ##(N) 打头，H1 不能使用，会自动转换成 H2。

> NOTE: 别忘了 # 后面需要有空格！

#### Heading 4

##### Heading 5

###### Heading 6

### 代码块

#### 普通

```
*emphasize*    **strong**
_emphasize_    __strong__
@a = 1
```

#### 语法高亮支持

如果在 \`\`\` 后面更随语言名称，可以有语法高亮的效果哦，比如:

##### 演示 Ruby 代码高亮

```ruby
class PostController < ApplicationController
  def index
    @posts = Post.desc("id).limit(10)
  end
end
```

##### 演示 Rails View 高亮

```erb
<%= @posts.each do |post| %>
<div class="post"></div>
<% end %>
```

##### 演示 YAML 文件

```yml
zh-CN:
  name: 姓名
  age: 年龄
```

> Tip: 语言名称支持下面这些: `ruby`, `python`, `js`, `html`, `erb`, `css`, `coffee`, `bash`, `json`, `yml`, `xml` ...

### 有序、无序列表

#### 无序列表

- Ruby
  - Rails
    - ActiveRecord
- Go
  - Gofmt
  - Revel
- Node.js
  - Koa
  - Express

#### 有序列表

1. Node.js
  1. Express
  2. Koa
  3. Sails
2. Ruby
  1. Rails
  2. Sinatra
3. Go

### 表格

如果需要展示数据什么的，可以选择使用表格哦

| header 1 | header 3 |
| -------- | -------- |
| cell 1   | cell 2   |
| cell 3   | cell 4   |
| cell 5   | cell 6   |

### 段落

留空白的换行，将会被自动转换成一个段落，会有一定的段落间距，便于阅读。

请注意后面 Markdown 源代码的换行留空情况。)
