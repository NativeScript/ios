var fetch = require("./fetch");

var JSCanvasViewController = UICollectionViewController.extend({
    numberOfSectionsInCollectionView: function() {
        return 1;
    },

    collectionViewNumberOfItemsInSection: function(collectionView, section) {
        return this.items.length;
    },

    collectionViewCellForItemAtIndexPath: function(collectionView, indexPath) {
        var cell = collectionView.dequeueReusableCellWithReuseIdentifierForIndexPath("Cell", indexPath);

        var imageView = cell.contentView.viewWithTag(1);

        imageView.image = UIImage.imageNamed("reddit-default");

        var item = this.items[indexPath.item];

        fetch(item["thumbnail"])
            .then(data => imageView.image = UIImage.imageWithData(data))
            .catch(error => console.log(error.toString()));

        return cell;
    },

    prepareForSegueSender: function(segue, sender) {
        if (segue.identifier == "showDetail") {
            var path = this.collectionView.indexPathsForSelectedItems;
            var itemPath = path.firstObject;
            var item = this.items[itemPath.item];

            var destinationViewController = segue.destinationViewController;
            destinationViewController.item = item;
        }
    }
}, {
    name: "JSCanvasViewController"
});
