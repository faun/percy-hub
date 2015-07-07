RSpec.describe Percy::Stats do
  let(:stats) { Percy::Stats.new }

  it 'sets environment tag' do
    expect(stats.tags).to eq(['env:test'])
  end
end

