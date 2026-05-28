./doc_assembler.sh


 3853  flatpak install flathub com.github.qarmin.czkawka
 3854  flatpak run com.github.qarmin.czkawka cli
 3855  czkawka_cli similar-images

git clone https://github.com/qarmin/czkawka.git
 3861  cd czkawka
 3862  cd czkawka_cli
 3863  cargo run --release --bin czkawka_cli
 3864  czkawka_cli
 3865  rustup install nightly
 3866  rustup override set nightly
 3867  cargo run --release --bin czkawka_cli
 3868  #flatpak run com.github.qarmin.czkawka similar-images \\n  --path "/media/ayoub/data/private" \\n  --similarity 85 \          # Adjust threshold (70–95)\n  --min-file-size 100K \     # Ignore thumbnails\n  --dry-run    
 3869  czkawka_cli
cp /media/ayoub/data/repos/czkawka/target/release/czkawka_cli  /usr/bin/
 3877  sudo cp /media/ayoub/data/repos/czkawka/target/release/czkawka_cli  /usr/bin/
 3878  chmod +x /usr/bin/*
 3879  sudo chmod +x /usr/bin/*


  ./move_duplicates.sh /media/ayoub/data/private/albums/organized