#!/usr/bin/env ruby

begin
	require "io/console"
rescue LoadError
end
require_relative "sched_getter"

class SessionInterface
	def self.start
		puts "In order to get your work schedule you need to provide your login and password for myPage."
		print "Login: "
		login = gets.chomp
		password = get_password
		scrape_session = MyPageScheduleScraper.new login, password
		scrape_session.schedule_page
		while scrape_session.schedule_available?
			scrape_session.generate_schedule
			scrape_session.next_week
		end
		puts "\nNo further schedules available."
	end

	private
		if STDIN.respond_to?(:noecho)
			def self.get_password
				print "Password: "
				STDIN.noecho(&:gets).chomp
			end
		else
			# Legacy support for Ruby < 1.9
			def self.get_password
				`read -s -p "Password: " password; echo $password`.chomp
			end
		end
end

SessionInterface.start