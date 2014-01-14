# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #
# 																												#
# USELESS COMMENT BOX BY: 																#
# 																												#
#	 ___    ___     _   _ 																	#
#	|   \  /   | o | | / /____ 															#
#	| |\ \/ /| | _ | |/ // __ \ 														#
#	| | \__/ | || ||   (/  ____\ 														#
#	| |      | || || |\ \  \___ 														#
#	|_|      |_||_||_| \_\_____\ 														#
#	           ____ 																				#
#	          |    \ 																				#
#	          |  -  ) _____    ___  __            __  __ 		#
#	          |  __/ |  ___\ /  _  \\ \    __    / //    \	#
#	          |    \ | |    |  | |  |\ \  /  \  / /|  /\  |	#
#	          |  -  )| |    |  |_|  | \ \/ /\ \/ / | |  | |	#
#	          |____/ |_|     \ ___ /   \__/  \__/  |_|  |_| #
# 																												#
# 																												#
# TODO: Package up with bundler														#
# 																												#
#	TODO: Compare gathered data to existing .ics files			#
# 			and inform of any changes to schedule	 						#
#  																												#
# TODO: Add ability to automagically import to  					#
# 			Calendar application 															#
# 																												#
# TODO: GUI? Bah. Probably not.														#
# 																												#
# TODO: Check timecard against schedule for possible			#
# 			missing punches?																	#
# 																												#
# # # # # # # # # # # # # # # # # # # # # # # # # # # # # #

require "capybara/dsl"
require "capybara/poltergeist"
require "icalendar"

module CapybaraWithPhantomJs
	include Capybara::DSL

	def new_session
		Capybara.register_driver :poltergeist do |app|
			Capybara::Poltergeist::Driver.new(app)
		end

		Capybara.configure do |config|
			config.run_server = false # Aparrently I have to do this if I'm not locally testing
			config.default_driver = :poltergeist
			config.default_selector = :xpath
			config.ignore_hidden_elements = true
			config.app_host = "https://mypage.apple.com"
		end

		@session = Capybara::Session.new(:poltergeist)

		@session.driver.headers = { "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X" }

		@session
	end
end

class MyPageScheduleScraper
	include CapybaraWithPhantomJs

	def initialize username, password
		@username = username
		@password = password
	end

	def schedule_page
		unless @schedule_page
			new_session
			visit "/"
			wait_for { page.has_content? "Account Name" }
			login
			click_link "myTime"
			wait_for { page.has_content? "Current Timecard" }
			click_link "Schedule"
			wait_for { schedule_available? }
			@schedule_page = SchedulePage.new(Nokogiri::HTML.parse(page.html))
		end
		@schedule_page
	end

	def schedule_available?
		!page.has_content? "Schedule is not available for the selected week"
	end

	def no_schedule_available?
		page.has_content? "Schedule is not available for the selected week"
	end

	def generate_schedule
		schedule = WeeklySchedule.new @schedule_page.week_begins, @schedule_page.shift_array
		schedule.to_ics
	end

	def next_week
		next_week_begins_date = Date.parse(@schedule_page.week_begins) + 7
		if date_in_current_month? next_week_begins_date
			click_calendar_day(next_week_begins_date)
			@schedule_page = SchedulePage.new(Nokogiri::HTML.parse(page.html))
		else
			click_next_month next_week_begins_date
			click_calendar_day(next_week_begins_date)
			@schedule_page = SchedulePage.new(Nokogiri::HTML.parse(page.html))
		end
	end

	private
		def login
			fill_in "appleId", with: @username
			fill_in "accountPassword", with: @password
			click_on "submitButton2"
			wait_for("Login Timed Out") { page.has_button? "Sign Out" }
		end

		def date_in_current_month? date
			Date.parse(@schedule_page.week_begins).month == date.month
		end

		def click_calendar_day date
			day_number = date.day.to_s
			within("//div[@id = 'calendar-#{date.year}-#{date.month - 1}']") do
        # BUG FIX -> capybara finding multiple elements, use regex to exact match date
				find("//td[@class = 'weekend']", text: /\A#{day_number}\z/).click
			end
			wait_for { page.has_content?("Schedule begins #{date.strftime("%b %d, %Y")}") || no_schedule_available? }
		end

		# Clicks on the little arrow on the calendar to load the next month
		def click_next_month date
			find("//img[@id = 'right' and @class = 'arrow']").click
			wait_for { page.has_content? "#{date.strftime("%B %Y")}" }
		end

		# Helper method to allow waiting for a specific thing on the page to load
		# Times out after 10 seconds (1+2+3+4)
		# Expects a block that returns a boolean value
		def wait_for message = "Request Timed Out"
			latency = 0
			while latency < 5
				sleep latency
				return true if yield
				latency += 1
			end
			abort "\n" + ("#" * message.length) + "\n\n#{message}\n\n" + ("#" * message.length)
		end
end

class SchedulePage

	# Expects the myPage schedule page as a Nokogiri HTML object
	def initialize page=Nokogiri::HTML.parse(File.open("split_shift.html")) # default value for debugging
		@page = page
	end

	# Return string containing the date the week begins, i.e. "Sep 14, 2013"
	# Matches from the raw_schedule_text using a regex
	# http://rubular.com/r/OjRZ0q6cko
	def week_begins
		unless @week_begins
			@week_begins = raw_schedule_text.scan(/\w+\s\d{1,2},\s\d{4}/)[0]
		end
		@week_begins
	end

	# Gross & Ugly.
	# Returns an array where every item is a Shift object
	def shift_array
		unless @shift_array
			@shift_array = []
			days_of_week = %w[Saturday Sunday Monday Tuesday Wednesday Thursday Friday]

			# Establishing variable scope
			current_day = nil
			current_date = nil
			index_counter = 0
			shift = nil

			# Finds a day then creates shifts for that day from each following pair of times
			raw_schedule_array.each do |item|
				if days_of_week.member?(item)
					current_day = item
					# Figure out the date of the shift based on the day of the week & start date of the week
					current_date = Date.parse(week_begins) + days_of_week.index(item)
					index_counter = 0
				elsif index_counter == 0
					shift = Shift.new
					shift.day_of_week = current_day
					shift.date = current_date
					shift.start = item
					index_counter += 1
				elsif index_counter == 1
					shift.stop = item
					index_counter = 0
					@shift_array << shift
				end
			end
		end
		@shift_array
	end

	private
		# Returns a string with all the necessary information to extract that week's schedule
		def raw_schedule_text
			unless @raw_schedule_text
				xpath_to_schedule = "//div[@id = 'contentTimecard']/div/table/tbody/tr/td/table/tbody"
				@raw_schedule_text = @page.search(xpath_to_schedule).text
			end
			@raw_schedule_text
		end

		# Data structure for schedule: [Day, Start, End, Day, Start, End, (Start), (End), etc...]
		# Matched from the raw_schedule_text with a regex
		# http://rubular.com/r/xOOFBOKFMM
		def raw_schedule_array
			unless @raw_schedule_array
				@raw_schedule_array = raw_schedule_text.scan /[SMTWF]\w{2,5}day|\d{1,2}:\d{2}[A|P]M/
			end
			@raw_schedule_array
		end
end

# Data structure to represent a single shift on a single day
class Shift
	include Icalendar
	attr_accessor :day_of_week, :date, :start, :stop

	def initialize day_of_week=nil, date=nil, start=nil, stop=nil
		@day_of_week = day_of_week
		@date = date
		@start = start
		@stop = stop
	end

	def date
		@date.strftime("%b %d, %Y")
	end

	def start
		Time.parse(@start).strftime("%H:%M")
	end

	def stop
		Time.parse(@stop).strftime("%H:%M")
	end

	def not_scheduled?
		@start == "00:00AM" && @stop == "00:00AM"
	end

	def to_ical_event
		event = Event.new
		event.start = DateTime.parse(self.date + " " + self.start + " PST")
		event.end = DateTime.parse(self.date + " " + self.stop + " PST")
		event.description = "Work at Apple"
		event.summary = "Work (Apple)"
		event.location = "Apple Store University Village, 2656 Northeast University Village Street, Seattle, WA, US"
		event
	end
end

# Data structure to represent 1 week's Shifts
class WeeklySchedule
	include Icalendar
	attr_reader :week_begins

	def initialize week_begins, shift_array
		@week_begins = week_begins
		@shift_array = shift_array
	end

	def to_ics
		cal = Calendar.new
		@shift_array.each do |shift|
			cal.add_event shift.to_ical_event unless shift.not_scheduled?
		end
		cal.publish
		cal_string = cal.to_ical
		file_name = "Schedule from #{@week_begins}.ics"
		File.open(file_name, "w") { |io| io.write cal_string }
		print "\nYour schedule has been saved to:\n #{`pwd | tr -d '\n'`}/#{file_name}"
	end
end