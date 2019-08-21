# Usage: hg-clone.rb SOURCE-DIR DEST-DIR --target TARGET-REVISION --cutoff CUTOFF-REVISION --filter FILTER
#
# This program clones a mercurial repository to a new directory, changeset by changeset
# with the option of running a filter before each commit. The filter can be used for
# example to strip out secret data (such as code for unused platforms) from the code.
#
# --target TARGET-REVISION
#    The revision that the DEST-DIR should be updated to. This revision, and all its parent revisions
#    will be copied over to the dest dir. If no TARGET-REVISION is specified, the latest revision in
#    the repositiory will be used.
#
# --cutoff CUTOFF-REVISION
#    If specified, this should be a short revision number that acts as a cutoff for synching. If you
#    specify 100 for instance, no revisions before 100 will be brought over to DEST-DIR. Revisions
#    that have parents earlier than revision 100 will be reparented to have 100 as their revision.
#
# --filter FILTER
#    Specifies a program that should be run in the DEST-DIR before committing each revision.

require 'fileutils'
require 'find'
require 'optparse'

SEPARATOR = 'akjfawejalejflakjflakjef'

ShortLogItem = Struct.new(:rev, :node, :parents)
LongLogItem = Struct.new(:rev, :node, :parents, :desc, :branch, :date, :author)

class HgLog
	def initialize()
		@items = []
		@lookup = {}
	end

	def add(item)
		@items << item
		@lookup[item.rev] = item
		@lookup[item.node] = item
	end

	def [](i)
		return @items[i]
	end

	def lookup(r)
		return @lookup[r]
	end
end

class Hg
	def initialize(dir)
		@dir = dir
	end

	def version()
		return command("hg summary").scan(/parent: (.+):/).flatten.flatten.first.to_i
	end

	def long_version()
		return command("hg summary").scan(/parent: .+:(\w+)/).flatten.flatten.first
	end

	def exists?()
		return File.exists?(@dir) && File.exists?(File.join(@dir,".hg"))
	end

	def init()
		FileUtils.mkdir_p(@dir)
		command("hg init")
	end

	def update(version)
		command("hg update -r #{version}")
	end

	def log()
		log = HgLog.new
		lines = command(%Q{hg log --template "{rev},{node},{parents};"}).split(';').reverse
		lines.each_with_index do |line, i|
			rev,node,parents = line.split ','
			if !parents
				parents = log[i-1] ? [log[i-1].node] : nil
			else
				parents = parents.split().collect {|p| log.lookup(p[/(.*):/,1].to_i).node}
			end
			item = ShortLogItem.new(rev.to_i, node, parents)
			log.add(item)
		end
		return log
	end

	def info(item)
		long = LongLogItem.new(item.rev, item.node, item.parents)
		long.desc, long.branch, long.date, long.author = command(%Q{hg log -r #{item.node} --template "{desc}#{SEPARATOR}{branches}#{SEPARATOR}{date|isodate}#{SEPARATOR}{author}#{SEPARATOR}"}).split(SEPARATOR)
		return long
	end

	def nodes()
		command(%Q{hg log --template "{node},"}).split ','
	end

	def mapping()
		ns = nodes()
		summaries = command(%Q{hg log --template "{desc}#{SEPARATOR}"}).split(SEPARATOR)
		mapping = {}
		ns.each_with_index do |n, i|
			mapping[n] = n
			cloned_from = summaries[i][/\[clonedfrom:(.*?)\]/, 1]
			mapping[cloned_from] = n if cloned_from
		end
		return mapping
	end

	def node(rev)
		return nil unless rev
		return command(%Q{hg log -r #{rev} --template "{node}"})
	end

	def rev(r)
		return command(%Q{hg log -r #{r} --template "{rev}"}).to_i
	end

	def parents(node)
		parents = command(%Q{hg log -r #{node} --template "{parents}"}).split
		if parents.empty?
			parents = [rev(node) - 1]
		end
		return parents.collect {|rev| node(rev)}
	end

	def addremove(opts = {})
		command("hg addremove" + (opts[:similarity] ? " --similarity #{opts[:similarity]}" : ""))
	end

	def commit_with_info(info)
		command("hg commit -A --message #{quote(info.desc + "\n\n[clonedfrom:" + info.node + ']')} --date #{quote(info.date)} --user #{quote(info.author)}")
		return command("hg parent --template {node}")
	end

	def set_parents(p1, p2 = '')
		command("hg debugsetparents #{p1} #{p2}")
	end

	def branch(name)
		command("hg branch \"#{name}\"")
	end

	def earlier_than(hg, rev1, rev2)
		return rev(rev1) < rev(rev2)
	end

private
	def command(s)
		Dir.chdir(@dir) do
			result =  `#{s}`
			raise "Error running:\n    #{s}\n" unless $?.exitstatus == 0
			return result
		end
	end

	def quote(s)
		return '"' + s.gsub('"', '\\"') + '"'
	end
end

def copy(from, to)
	`robocopy #{from} #{to} /MIR /XD .hg`
end

def hg_clone_with_filter(from_dir, to_dir, opts = {})
	from = Hg.new(from_dir)
	to = Hg.new(to_dir)
	to.init unless to.exists?

	from_log = from.log()
	mapping = to.mapping()
	
	target = from.node(opts[:target]) || from_log[-1].node
	cutoff = from.node(opts[:cutoff]) || from_log[0].node
	cutoff_item = from_log.lookup(cutoff)
	
	queue = []
	queue << target

	while queue.size > 0 do
		node = queue.pop
		next if mapping[node]

		item = from_log.lookup(node)

		parent_1, parent_2 = item.parents
		if node == cutoff
			parent_1, parent_2 = nil, nil
		end
		
		parent_1_item = parent_1 ? from_log.lookup(parent_1) : nil
		parent_2_item = parent_2 ? from_log.lookup(parent_2) : nil
		
		if parent_1_item && parent_1_item.rev < cutoff_item.rev then
			parent_1 = cutoff 
			parent_1_item = cutoff_item
		end
		if parent_2_item && parent_2_item.rev < cutoff_item.rev then
			parent_2 = cutoff 
			parent_2_item = cutoff_item
		end
		if parent_1 && !mapping[parent_1] || parent_2 && !mapping[parent_2]
			queue << node
			queue << parent_1
			queue << parent_2 if parent_2
			next
		end

		to_parent_1 = parent_1 ? mapping[parent_1] : nil
		to_parent_2 = parent_2 ? mapping[parent_2] : nil

		info = from.info(item)
		puts "#{info.rev} #{info.desc}"
		from.update(node)

		if to_parent_1 then
			to.set_parents(to_parent_1, to_parent_2)
		else
			to.set_parents("0000000000000000000000000000000000000000")
		end
		to.branch(info.branch) if info.branch

		copy(from_dir, to_dir)

		# Avoid 'nothing changed' message
		Dir.chdir(to_dir) do
			File.open("cloned_revision.txt", "w") {|f| f.write(item.node)}

			if opts[:filter]
				`#{opts[:filter]}`
				raise "Error running:\n    #{opts[:filter]}\n" unless $?.exitstatus == 0
			end
		end

		to.addremove :similarity => 90
		mapping[node] = to.commit_with_info(info)
	end
end

usage = "Usage: hg-clone.rb SOURCE-DIR DEST-DIR [OPTIONS]"
options = {}
OptionParser.new do |opts|
	opts.banner = usage
	opts.on("--target TARGET-REVISION", "Target revision to copy to destination") do |v| options[:target] = v end
	opts.on("--cutoff CUTOFF-REVISION", "Cutoff revision -- ignore earlier revisions") do |v| options[:cutoff] = v end
	opts.on("--filter FILTER", "Filter to run before importing revision") do |v| options[:filter] = v end
	opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit
  	end
end.parse!

if ARGV.size != 2
	puts usage
	exit
end

hg_clone_with_filter(ARGV[0], ARGV[1], options)